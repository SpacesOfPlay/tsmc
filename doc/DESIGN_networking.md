# DESIGN — networking (net / http / https / fetch)

Scope for bringing Node-style networking to tsmc. Decisions locked with
the user: **client + server**, **Windows-first**, TLS via the existing
**picotls-minc** port (TLS 1.3 only). This is a cross-cutting change —
it reshapes the event loop — so it gets a design doc before any milestone
plan.

## 1. Goal / non-goal

**Goal.** Run ordinary networked Node code: `fetch()` and `http(s)`
requests outbound, `net.Socket` clients, and `http.createServer` /
`net.Server` inbound — over both plaintext and TLS 1.3, on Windows first.

**Non-goal (this design).** IPv6, UDP (`dgram`), HTTP/2, WebSocket as a
core module, TLS 1.2, session resumption / 0-RTT, and cluster/worker
networking. Linux/macOS ports come after the Windows path proves out.

## 2. The core problem: the loop must become a reactor

`vm_run_event_loop` (src/vm.mc) runs on **virtual time and never
sleeps** — it drains microtasks, fires the earliest timer immediately,
and exits when both are empty. The current "async" `fs` is
**fake-async**: it does the blocking syscall, then schedules the callback
on a resolved-promise microtask (`fs_schedule_cb`). That is fine for a
local file and fatal for a socket — a blocking `recv` would freeze the
whole VM.

Networking forces a real reactor. The loop becomes:

```
while jobs pending OR any alive timer OR any ref'd handle:
    drain the microtask/job queue            (unchanged)
    now      = os_mono_ns()                   (real clock; already exists)
    timeout  = nearest timer due - now        (0 if a timer is ready;
                                               ∞ if only handles are live)
    poll the registered sockets for `timeout` (WSAPoll)
    dispatch every ready socket (accept / connect-done / readable / writable)
    fire every timer now due
```

Two consequences worth stating: `setTimeout` starts honoring **real**
wall-clock delay (arguably more correct than today's ordering-only
model), and process exit is now governed by a **handle ref-count**, not
just an empty timer list — Node's ref/unref. An open connection or a
listening server keeps the loop alive; `unref()` drops that.

## 3. Layers

```
  JS:  fetch / Headers / Request / Response
       http / https  (ClientRequest, IncomingMessage, Server)
       net.Socket / net.Server         (EventEmitters)
  ---------------------------------------------------------------
  C-ish runtime (tsmc src/):
       reactor          (poll loop, handle table, ref-count)
       NetHandle        (fd + interest + queued buffers + optional TLS)
       TLS pump         (picotls: handshake / ptls_send / ptls_receive)
       socket syscalls  (non-blocking Winsock + WSAPoll + getaddrinfo)
```

### 3.1 Socket primitives (tsmc-owned)

`minc/lib/net.mc` gives blocking IPv4 TCP (`net_listen/accept/connect/
recv/send/close`) but no non-blocking mode, no poll, no DNS — and it
lives in the **gitignored** minc deploy, so we must not depend on editing
it. The runtime declares the extra Winsock externs itself in a new
`src/net_os.mc` (or inside builtins): `ioctlsocket(FIONBIO)` for
non-blocking, `WSAPoll` for readiness, `getsockopt(SO_ERROR)` for
connect completion, and `getaddrinfo`/`freeaddrinfo` for DNS. net.mc's
plain `socket/bind/listen` are reused where convenient.

Non-blocking specifics: `connect` returns `WSAEWOULDBLOCK`; completion is
signaled by writability in WSAPoll, then confirmed via `SO_ERROR`.
`recv`/`send` return `WSAEWOULDBLOCK` when they'd block, which drives the
readable/backpressure logic.

### 3.2 NetHandle + GC

A `NetHandle` (a Vec entry in `vm.handles`) holds: `fd`, kind
(listener / connecting / connected), interest mask, a queue of pending
write buffers, the JS-visible `Socket`/`Server` object it dispatches
events to, and — when secure — the TLS state (`ptls_t*` plus in/out
`ptls_buffer_t`). The reactor marks each handle's JS object during GC so
an in-flight connection with registered listeners is never collected; a
handle finalizer `closesocket`s a dropped fd. This is the main new GC
rooting surface and the place bugs will hide — it gets `--gc-stress`
coverage from day one.

### 3.3 `net` (Socket / Server)

`net.Socket` and `net.Server` are thin EventEmitters over a NetHandle.
Readable ready → `recv` into scratch → emit `'data'` (a `Buffer`);
EOF → `'end'`/`'close'`; writable ready → drain the write queue,
emit `'drain'`. `server.listen()` registers a listener handle;
acceptable → `accept`, wrap the new fd, emit `'connection'`. `.ref()`/
`.unref()` toggle the handle's liveness contribution.

### 3.4 `http` / `https` / `fetch`

Above `net`: an HTTP/1.1 codec (request writer + streaming response
parser with chunked transfer-encoding and keep-alive). `http`/`https`
expose `request`/`get`, `ClientRequest`, `IncomingMessage`, and
`createServer`. `fetch` + `Headers`/`Request`/`Response` wrap the client
codec and resolve a Promise with a `Response` whose body is available as
`.text()`/`.json()`/`.arrayBuffer()`. `https` is exactly `http` over a
TLS handle (§4).

## 4. TLS via picotls-minc

picotls-minc (`../picotls-minc`) is a pure-minc TLS 1.3 stack (cifra +
monocypher, no system TLS, no external deps). Critically its core is
**transport-agnostic and buffer-based** — verified in
`examples/02_in_memory_handshake.mc` — and every function we need is
exported top-level:

- `ptls_new(ctx, is_server)` / `ptls_free`
- `ptls_handshake(tls, sendbuf, input, &inlen, props)` — 0 = done,
  514 = wants more; consumes `inlen`, emits handshake bytes to `sendbuf`
- `ptls_receive(tls, plainbuf, input, &inlen)` — decrypt inbound records
- `ptls_send(tls, sendbuf, plaintext, len)` — encrypt outbound
- `ptls_handshake_is_complete(tls)`

So TLS drops onto a non-blocking socket with **no threads**: the reactor
reads ciphertext → `ptls_receive` → plaintext to the HTTP layer; the HTTP
layer writes plaintext → `ptls_send` → ciphertext queued to the socket.
picotls never touches an fd. Context setup (cipher-suite / key-exchange
vtables, `random_bytes`, `get_time`) is boilerplate copied from the
examples and built once per process.

### 4.1 The real gap: certificate trust

picotls-minc verifies certificates by **SPKI pinning**, *not* CA-bundle
chain validation (README "what doesn't"). Node's `fetch`/`https` instead
validates the server chain against a trusted root store with
hostname/SAN and validity checks. Pinning cannot express
`fetch('https://any-host')` securely. Closing this is the single largest
sub-task and needs its own decision:

- **(a) CA-chain verifier** plugged into picotls's `verify_certificate`
  callback: parse the presented X.509 chain, verify each signature up to
  a **bundled root store** (~130 KB of Mozilla roots), check dates and
  SAN. The signature primitives already exist (RSA-PSS/PKCS1, ECDSA-P256,
  Ed25519 via the bridges); the work is X.509 chain parsing + path
  building + the root bundle. **Likely needs a new `transminc` export**
  (the user flagged the port is stale) to reach picotls's cert-parsing
  internals or additional verify primitives.
- **(b) Ship pin/insecure first**: expose `fetch` with correct behavior
  only when a pin is supplied, plus an explicit opt-in
  `rejectUnauthorized:false`-style bypass, and land (a) in a later
  milestone. Unblocks development end-to-end without pretending to be
  secure.

Recommendation: build the plumbing against option (b) so the reactor and
HTTP layers land and are testable, and schedule the CA-chain verifier
(a) as the milestone that makes HTTPS trustworthy — treating the
transminc re-export as an explicit dependency/risk, not a surprise.

**Resolved (M35, doc/PLAN_M35_ca_trust.md).** Option (a) shipped and
HTTPS is now secure by default. The flagged transminc dependency did
**not** materialize: rather than reach picotls's cert-parsing internals,
tsmc has its own defensive X.509 parser (`src/tls_x509.mc`) and path
validator (`src/tls_chain.mc`), and the only addition to the vendored
crypto was one generic `in^e mod n` wrapper (`mc_rsa_pub_modexp`) over
the existing bignum. The signature primitives were reused from the
bridges (RSA-PKCS1-v1_5 built in `tls_verify.mc`, ECDSA-P256 via uECC)
and extended with a self-contained ECDSA-P384 (`src/tls_p384.mc`), since
the vendored uECC is P-256 only. Trust anchors come from a generated
Mozilla bundle (`src/tls/ca_roots_data.mc`). The `verify_certificate`
callback validates the chain to a store root, checks validity and the
SAN hostname, and arms the CertificateVerify check; `rejectUnauthorized:
false` / `NODE_TLS_REJECT_UNAUTHORIZED=0` opt out. Out of scope, still:
revocation (OCSP/CRL), name/policy constraints, an updatable store, and
P-521 chains (one Mozilla root; it fails closed).

### 4.2 Vendored, but not yet co-compilable — the generic-param blocker

The TLS core is vendored into `src/tls/` (subset only; see
`src/tls/THIRD_PARTY.md`) and verified to build + run a full TLS 1.3
handshake standalone (`test/tls/handshake_selftest.mc`). It does **not
yet co-compile into the `tsmc` binary**: importing it alongside the tsmc
stack is blocked by a minc parser issue.

minc registers **generic type-parameter names in the global parse
namespace**, so a bare `T`/`V` used as a *local variable* is misparsed as
a type-first array declaration (`T[i] = x` → "expected IDENT"). tsmc's
containers leak exactly two such names — `V` (`IntMap<V>`/`StrMap<V>` in
`src/map.mc`) and `T` (`Vec<T>` in stdlib `vec.mc`) — and the
transminc-ported crypto uses `T`/`V` as locals (e.g. the uECC RFC-6979
nonce loop). Concretely:

- **`V`** is fixable tsmc-side (rename the `map.mc` parameter; there is no
  stdlib `map.mc`, so `src/map.mc` is authoritative).
- **`T`** is *not* — `import vec;` resolves to stdlib `vec.mc` even when a
  `src/vec.mc` fork exists (stdlib wins for names present there), and the
  deploy's `vec.mc` is gitignored/refreshed.

The clean fix is at the root, which we own: either **scope generic type
parameters in minc** so they don't pollute the global type namespace
(fixes this for *all* transminc-ported code, not just picotls), or have
**transminc avoid emitting single-letter locals** that collide. Patching
the vendored crypto's locals would work but re-breaks on every re-export,
so it is not the plan. This blocker gates the "https over TLS" stage, not
the plaintext `net`/`http` stages, so it does not hold up M32.

## 5. DNS

`net_connect` takes a raw `u32` IP; real code passes hostnames. Add
`getaddrinfo` (IPv4 A records first). It is a **blocking** call; for the
first cut, resolve synchronously at connect time (a brief stall). Node
offloads DNS to its threadpool — a future improvement, deferred because
tsmc's GC is single-threaded and a threadpool is its own hazard.

## 6. Suggested staging (each lands green + `--gc-stress`)

Stages 1–4 shipped as M31–M35; stage 5 (servers) is the open one.

1. **Reactor.** (M31) Convert `vm_run_event_loop` to a real poll loop with
   the handle table, real-clock timer integration, and ref-counting. No new
   JS surface yet; existing timer/promise tests must stay byte-identical.
   *Highest-risk stage — it touches the loop everything else depends on.*
2. **`net` client + DNS.** (M32) `net.Socket`, `net.connect`,
   `getaddrinfo`; an echo-client diff test against a local listener.
3. **`http`/`https` client + `fetch`** (M33/M34) over plaintext + TLS
   handles. Loopback HTTP diff tests.
4. **CA-chain certificate verification** (M35, §4.1) — makes real-world
   `fetch('https://…')` trustworthy. Secure by default; no transminc
   re-export was needed after all.
5. **Servers.** `net.Server` + `http.createServer` (accept loop in the
   reactor), then TLS server via picotls server mode. `net.Server` /
   `http.createServer` already landed in M32/M33 (see `node_net.mc` /
   `node_http.mc`); the TLS server side is the remaining piece.

## 7. Risks / open items

- **Reactor regressions.** Making timers real-time and exit
  handle-driven must not perturb existing async ordering. Mitigate with
  the current async/timer/promise diff tests as a fixed baseline.
- **transminc dependency.** The CA-verifier stage (and possibly some
  context helpers) may require regenerating picotls-minc from an updated
  transminc. Flagged by the user; treated as a scheduled dependency for
  stage 4, not a blocker for stages 1–3.
- **Binary size / build.** picotls_lib.mc is ~25 K lines of pure minc;
  importing it grows the tsmc build materially. Verify compile + startup
  cost early.
- **No threads, by design.** Everything stays on the single VM thread;
  tsmc's mark-sweep GC is not concurrent, so the threaded pattern in
  `examples/03_concurrent_https.mc` is explicitly *not* the model here.
- **Testing real hosts is non-deterministic.** Prefer loopback
  client+server diff tests; keep any live-internet check out of the
  gated suite.

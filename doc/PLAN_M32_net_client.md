# PLAN M32 — sockets on the reactor: `net` (client + server)

Stage 2 of `doc/DESIGN_networking.md`. Puts real non-blocking TCP on the
M31 reactor and exposes Node's `net` (Socket + Server) plus DNS. Plaintext
only — TLS rides on this later and is unblocked separately (§4.2 blocker).

## Increments (each builds + tests green)

1. **`src/net_os.mc` — the OS socket layer (this increment).**
   Windows-first Winsock: non-blocking `socket`/`connect`/`bind`/`listen`/
   `accept`/`recv`/`send`/`close`, `ioctlsocket(FIONBIO)`,
   `getsockopt(SO_ERROR)` for connect completion, `getsockname` for the
   bound port, `WSAPoll` for readiness, and `getaddrinfo` for DNS. Sits
   below builtins/vm (like `os_time.mc`) so both the reactor and the `net`
   module can call it. Proven by a native loopback echo unit test
   (`test/unit/test_net_os.mc`) — no JS, no reactor yet.
2. **Reactor poll integration.** `vm_run_event_loop`'s wait becomes
   `WSAPoll(handle fds, timeout)` instead of `Sleep` when any handle is
   registered; ready fds are dispatched through a hook the `net` module
   installs (keeps vm.mc from depending on builtins). Connect-complete,
   readable, writable(drain), and listener-acceptable each map to a hook
   call.
3. **`net` module.** `net.Socket` / `net.Server` as EventEmitters over
   the handle table: `net.connect`/`createConnection`, `server.listen`,
   `'connection'`/`'connect'`/`'data'`/`'end'`/`'error'`/`'close'`,
   `socket.write`/`end`, `.ref`/`.unref`. Native primitives create/close
   handles and do I/O; the dispatch hook emits events into JS.
4. **DNS surface.** `net.connect({host})` resolves via `getaddrinfo`
   (blocking at connect for now — documented; threadpool later).

## This increment's deliverable (net_os.mc)

A self-contained, non-blocking Winsock wrapper with a byte-level loopback
test that connects a client to an ephemeral loopback listener, accepts,
and round-trips a payload — all through `WSAPoll`, proving connect/accept/
recv/send/close and readiness reporting before any reactor or JS wiring.

## Out of scope (later stages / milestones)

- TLS/`https` (gated on the minc generic-param fix, DESIGN §4.2).
- `http`/`fetch` (M33).
- IPv6, UDP, `unix:` sockets, Linux/macOS ports.
- Threadpooled DNS (blocking resolve is the first cut).

## Shipped

All four increments landed:

1. **`src/net_os.mc`** — Windows non-blocking Winsock + `WSAPoll` + DNS
   (`test/unit/test_net_os.mc`).
2. **Reactor poll** — `vm_run_event_loop` `WSAPoll`s live handles bounded
   by the next timer, dispatching ready fds through a `ReactorHook`
   (`test/unit/test_reactor_net.mc`).
3. **`net` module** — `src/node_net.mc` (JS-source): `net.Socket` /
   `net.Server` on `EventEmitter`, `connect`/`createConnection`,
   `createServer`, `server.listen`, `'connect'`/`'data'`/`'end'`/
   `'error'`/`'close'`/`'drain'`/`'connection'`/`'listening'`,
   `socket.write`/`end` with a JS write-queue + backpressure, `.ref`/
   `.unref`, `server.address()`/`close`. Native primitives (`__net_*` in
   builtins.mc) do the I/O; the reactor hook calls `owner.__onReady`.
4. **DNS** via `net_os_resolve4` (blocking at connect).

Verified byte-identical to Node in `test/diff/net.js` (loopback echo) and
clean under `--gc-stress`; a 200 KB round-trip exercises multi-recv and
send backpressure. Full suite green (53 tests, 67 gc-stress scripts).

Deviation: the native `__net_*` primitives are installed as
non-enumerable globals the JS module calls, rather than a native module
namespace — simplest bridge, and they don't appear on `globalThis` keys.
`net` is registered as a JS-source core module (`builtin_name` +
`builtin_js_source`), like `stream`/`assert`.

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

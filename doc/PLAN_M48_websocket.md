# M48 — WebSocket

Status: complete. I1 and I2 landed 2026-09-27, I3 and I4 on 2026-09-28.

## Goal

Run WebSocket code the way Node 22 runs it. Node has two halves and tsmc
takes the same split:

- A **`WebSocket` global** — the WHATWG client (`new WebSocket(url)`,
  `open`/`message`/`error`/`close` events, `send`, `close`). Node's core
  has no server.
- **Servers come from packages** — `ws`, and everything built on it
  (socket.io, most frameworks' `.ws()` routes) — through the `'upgrade'`
  event on `http.Server` and `http.ClientRequest`, which hands the raw
  socket to the package after the HTTP handshake.

So the deliverable is: the upgrade seam in `http`, the `WebSocket` client
global with its data types, and the few core gaps that stop `ws` from
loading today. `ws` running unmodified is the acceptance test for the
server side; the diff tests cover the client and the seam.

**Non-goals.** A built-in server API (Node has none; `ws` is the server).
`permessage-deflate` (Node's client never negotiates it; the `ws` server
defaults to off) — needs streaming raw deflate/inflate in `zlib`, its own
milestone if ever wanted. `WebSocketStream` (not in Node 22). Proxies,
cookies, HTTP/2 upgrades, `CONNECT` (same seam, later).

## Where things stand

As of 2026-09-28: `require('url')` exists, `http.Server` and
`http.ClientRequest` emit `'upgrade'`, both sockets have the shape a frame
codec needs (`unshift`, `cork`/`uncork`, `pause`/`resume`, a write queue
with `'drain'`, `_writableState`/`_readableState`), `Buffer` is a
`Uint8Array`, `bufferutil` and `utf-8-validate` are built in over natives,
and the `WebSocket`, `MessageEvent` and `Blob` globals exist. `ws` 7.5.10
runs unmodified over http and https, including large messages, and the
`WebSocket` global talks to it, over `ws:` and `wss:`. Nothing remains open.

The state on 2026-09-27, for the record: `ws` failed at `require('url')`,
then on `http.STATUS_CODES[426]`, then for want of `'upgrade'`; `Buffer`
was a JS array (no `set`, `.buffer`, `.byteOffset`); `TLSSocket` had no
write queue, always answered `true` and dropped bytes on a failed write.

## Design

### 1. The upgrade seam in `http` (the one structural change)

**Server.** In `serveConnection`, once the head is parsed: if the request
carries `Upgrade:` and `Connection: upgrade` and the server has an
`'upgrade'` listener, the parser steps aside — clear the deadline, remove
the `data`/`end`/`close` listeners it installed, mark the connection as
handed over, and `emit('upgrade', req, socket, head)` where `head` is
whatever arrived after the request head. Those bytes travel only as
`head`, never as a later `'data'`. No listener: the request is served
like any other, `req.upgrade` false, as in Node. `req` is an
`IncomingMessage` with no body and `req.upgrade` true.

**Client.** In `ClientRequest._parse`, a `101` with `Upgrade:` does the
same: detach, `emit('upgrade', res, socket, head)`; no listener destroys
the socket. `res.headers` lets the caller check `Sec-WebSocket-Accept`.

**Socket.** `unshift(chunk)` puts bytes back in front of the next read:
delivered on the next `'data'` turn, before anything new from the wire.
`ws` calls `socket.unshift(head)` on both sides. Also the small shape
`ws` reads off a socket: `cork`/`uncork` no-ops, `_writableState.length`
(bytes still queued, which `net.Socket` already tracks in its write
queue) for its `bufferedAmount`.

The emit is synchronous, inside the `'data'` turn that completed the head,
as in Node — the listener may write to the socket at once. What matters is
that the parser's own listeners are gone before the next chunk arrives.

**TLS.** An `https` server is `http.Server` over `tls.createServer`, so the
seam covers it with no change of its own, but the socket handed over is a
`TLSSocket`, and `ws` needs the same shape of it:

- `unshift`, `cork`/`uncork` and `pause`/`resume`, as on `net.Socket`.
- A write queue, as `net.Socket` has: `write` queues what `__tls_write`
  does not take and flushes it on the reactor's write-ready turn; it returns
  `false` while the queue (plaintext queued plus ciphertext the session still
  holds) is past a high-water mark, and emits `'drain'` when it empties.
  `_writableState.length` is the queued byte count, which `ws` reports as
  `bufferedAmount`. A slow peer then holds its queue at the mark instead of
  growing it.
- A failed `__tls_write` destroys the socket with an `'error'`, never drops
  the rest of the buffer silently: on a framed stream a lost span corrupts
  every message after it.

### 2. The `WebSocket` global

New `src/node_websocket.mc`, a JS-source internal module `_websocket` in
the pattern of `_fetch`/`_webapi`; `WebSocket` and `MessageEvent` become
lazy globals, so a script that never mentions them pays nothing.

- **Constructor** `(url, protocols)`: `ws:`/`wss:`, and `http:`/`https:`
  mapped onto them; a fragment or a bad scheme is a `SyntaxError`
  `DOMException`; `protocols` is a string or array, validated and
  de-duplicated.
- **Handshake** over `http.request` / `https.request` and the `'upgrade'`
  event: a random 16-byte key, `Sec-WebSocket-Version: 13`, the accept
  key verified (SHA-1 + base64 of key + GUID), the chosen subprotocol must
  be one offered. Anything else fails the connection: `'error'` then
  `'close'` with `1006`, `wasClean: false`.
- **Frames** (JS over Buffer): FIN/RSV/opcode, 7/16/64-bit lengths;
  every client frame masked with a fresh 4-byte key; fragmented messages
  reassembled; control frames must be unfragmented and ≤ 125 bytes;
  `ping` answered with `pong` automatically; RSV bits set → `1002` (no
  extensions are negotiated); text that is not UTF-8 → `1007` (the fatal
  `TextDecoder` decides); a length past the limit → `1009`; a bad close
  code → `1002`.
- **Close handshake**: `close(code, reason)` validates the code
  (1000 or 3000–4999) and the reason (≤ 123 UTF-8 bytes), sends the close
  frame, moves to `CLOSING`, and ends the socket when the peer's close
  frame arrives or a timeout passes. The `'close'` event carries `code`,
  `reason`, `wasClean`; a dropped connection is `1006`.
- **Messages**: text arrives as a string; binary as a `Blob` (Node's
  default `binaryType`) or an `ArrayBuffer`. `send` takes a string,
  `ArrayBuffer`, `ArrayBufferView` or `Blob`. `bufferedAmount` is the
  bytes accepted by `send` and not yet handed to the wire.
- **Events**: on `EventTarget`; `onopen`/`onmessage`/`onerror`/`onclose`
  accessors; the four `readyState` constants on both the class and the
  prototype; `url`, `protocol`, `extensions` (always `''`).
- **`MessageEvent`** (`data`, `origin`, `lastEventId`, `source`, `ports`)
  joins `node_webevents.mc` as a global; **`CloseEvent`** is defined there
  too but not published on `globalThis`, matching Node 22.
- **`Blob`**: a minimal global — parts, `size`, `type`, `arrayBuffer()`,
  `text()`, `bytes()`, `slice()`. Also closes the `Response.blob()` gap.
- **Masking cost**: a byte-wise XOR loop in JS first; if a 1 MB message
  costs more than a few ms, one native helper `__ws_mask(buf, key, off)`.
  Measure before adding it.

### 3. Small core gaps

- **`require('url')`**: `URL`, `URLSearchParams`, `fileURLToPath`,
  `pathToFileURL`, `format`, `domainToASCII`/`domainToUnicode`, and the
  legacy `parse`/`resolve` returning the legacy object shape (`protocol`,
  `auth`, `host`, `port`, `hostname`, `hash`, `search`, `query`,
  `pathname`, `path`, `href`). A gap in its own right — a great many
  packages `require('url')` — so it lands first, on its own.
- **`http.STATUS_CODES`**: the full Node table (63 entries), not the
  handful used by the server's own replies.

## Increments

Each lands with its own tests and leaves the suite green.

- **I1 — `url` module + full `STATUS_CODES`.** Done. `test/diff/url_module.js`:
  `parse`/`format`/`resolve`/`fileURLToPath`/`pathToFileURL` over a fixed
  list of inputs, vs Node. Also fixed on the way: `path.resolve` kept a
  trailing separator.
- **I2 — the upgrade seam + `socket.unshift`.** Done. `test/diff/http_upgrade.js`:
  `http.request` with `Upgrade:` and a server `'upgrade'` listener, raw
  bytes echoed over the handed socket; a case where the client's first
  payload rides in the same write as the request head, so `head` is
  non-empty on the server; a server without a listener (socket closed);
  a client without one; the same exchange over `https.createServer`, the
  server's `'upgrade'` handing over a `TLSSocket`.
  `test/diff/tls_write_queue.js`: a `TLSSocket` writing a few MB to a peer
  that reads slowly — `write` turns `false`, `'drain'` follows, every byte
  arrives in order; `_writableState.length` falls back to 0. Acceptance: the
  `ws` echo script (client + server in one process, text and binary, clean
  close) prints the same as under Node, over `http` and over `https`.
  Landed with it: `TLSSocket.end()` is a half-close (close_notify, then
  the FIN once the ciphertext has drained, reading on until the peer's
  EOF), so the close order matches a plain socket and Node; both sockets
  carry `_readableState.endEmitted` and `_writableState.finished`;
  `stream.Writable` exposes `_writableState`; `Object.defineProperty` with
  a generic descriptor (`{ enumerable: true }`) keeps an existing accessor
  instead of replacing it with `undefined` — that one alone stopped `ws`
  from ever opening.
  **Acceptance result:** `ws` 7.5.10 unmodified, echo of a text and a small
  binary message with a clean `1000` close, over http and over https,
  prints what Node prints. A message that arrives in more than one chunk
  does not: `ws` reassembles with `Buffer.prototype.set` and a
  `Uint8Array` view over `buf.buffer`/`buf.byteOffset`, and `Buffer` here is
  still array-backed. That is `doc/PLAN_M42_buffer_uint8array.md`, and the
  `ws` server story is complete once it lands; nothing in this milestone
  can substitute for it.
- **I3 — `WebSocket` + `MessageEvent` + `Blob`.** Done. `src/node_websocket.mc`
  is the client: handshake over `http.request` and `'upgrade'` (key, accept
  check, subprotocol rules, no extensions), RFC 6455 framing over the two
  natives, fragmentation, ping/pong, both directions of the close
  handshake with code validation, `binaryType` `blob`/`arraybuffer`,
  `bufferedAmount`, the `onopen`/`onmessage`/`onerror`/`onclose`
  properties, the four constants on class and prototype. `MessageEvent`,
  `CloseEvent` and `ErrorEvent` live in `_webevents` (only the first is a
  global, as in Node 22); `Blob` lives in `_webapi`, and `Response.blob()`
  came with it. `test/diff/websocket.js` carries a small frame server on an
  `http` `'upgrade'` listener and runs the same 81 lines on both runtimes:
  text and binary echo in both `binaryType` modes, 70 KB and 200 KB
  messages (16- and 64-bit lengths), a Blob and a number sent, a fragmented
  message, a ping answered, client- and server-initiated close with code
  and reason, `wasClean`, event order, `readyState` at each step,
  `bufferedAmount`, the constructor's and `close()`'s argument errors, the
  handler properties, and the failures: a subprotocol not offered or not
  selected, a wrong accept key, a non-101 reply, invalid UTF-8, a reserved
  bit, a dropped connection. Byte-identical to node, also under
  `--gc-stress`. The global also talks to the `ws` package's server: text,
  binary, 70 KB and 200 KB, clean close, same output as node.
  **Where node 22 differs from the standard, this runtime follows the
  standard, and the test asserts only what both agree on:** after a failed
  handshake node fires `'error'` and leaves the socket `CONNECTING` for
  good, with no `'close'`; here `'error'` is followed by `'close'` with
  1006 and the state is `CLOSED`. `close()` while connecting fires
  `'error'` twice in node. And node reports `readyState` 1 from inside the
  `'error'` handler of a data-phase failure where the standard (and this
  runtime) has already moved to `CLOSED`.
  Measured against the `ws` server in one process, 2026-09-28: 64 B
  messages 22.7k round trips/s (node's client on the same server: 36.1k),
  4 KB 114 MB/s (node 121), 1 MB 533 MB/s (node 306).
  The 64 B case taken apart: the bare socket round-trips 64 B at 86–95k/s
  (node 96–106k), so ~11 µs of every round trip is system calls on both
  runtimes. Against a lean raw frame server (no `ws` on either end) the
  client went from 35k to 56k/s over two rounds (node's client: 57–59k on
  the same server; the `ws` client here: 38k), guided by the profiling
  build (`build --prof`), which charges time and ops to JavaScript
  functions. Round one: mask keys from a pool instead of a generator call
  per frame, `bufferedAmount` read off the socket's queue instead of a
  callback and microtask per write, frames parsed at an offset into the
  chunk they arrived in, a Uint8Array sent as it is, one-listener dispatch
  without a snapshot. Round two, from the profile: `fillMask` was 10% of
  all ops for a 4-byte copy and the `Event`/`MessageEvent` constructors 13%
  — an event's defaults now live on its prototype (as the standard's
  accessors do; node's events have no own properties at all) and the
  message event is built directly; a native draws the mask key and masks
  the payload in one call; a native decodes and checks a frame header into
  one packed number; and `socket.write` with nothing queued sends straight
  away instead of queueing, coalescing and flushing, and a header and its
  payload written between `cork()` and `uncork()` go out in one native send
  without being joined first — the two of which also took the `ws`
  package's own round trips from 19.2k to 20.7k. Ops per round trip fell
  from 1,060 to 690, allocations from 27 to 25.
  The other ~26 µs of the 46 µs round trip with `ws` on the server side is
  the `ws` package's own code — a stream, a state machine and several
  emits per frame, run by the interpreter — which node runs through a JIT;
  the profile of that run names `getInfo`, `consume`, `frame`, `send` and
  `startLoop` in `ws`, and nothing of ours above 10%.
- **I4 — `wss:`.** Done. `test/diff/websocket_tls.js`: an `https.createServer`
  on the existing fixture certificate with an `'upgrade'` listener running
  the frame server over the `TLSSocket` it is handed, and the global as the
  `wss:` client — a fragmented greeting that arrives with the handshake's
  tail, echo, 70 KB binary and 200 KB text, a clean close. Verification is
  switched off by `NODE_TLS_REJECT_UNAUTHORIZED=0`, which both runtimes read
  at connect time; node announces the switch with a warning on stderr,
  which the script silences (`process.removeAllListeners('warning')`), as
  the harness compares stderr. Byte-identical to node, also under
  `--gc-stress`. A connection to a public endpoint stays a manual check.

## Performance

Measured 2026-09-27 before I3, with the `ws` package echoing between a
client and a server in one process on loopback (node 22.16 for reference,
same script). Round trips per second and bytes on the wire (payload both
ways):

| | node | tsmc before | tsmc after |
|---|---|---|---|
| 64 B messages, 100 in flight | 37k msg/s | 13k msg/s | 19.2k msg/s |
| 4 KB messages | 144 MB/s | 4.5 MB/s | 95 MB/s |
| 1 MB messages | 462 MB/s | 2.4 MB/s | 571 MB/s |
| raw `net` echo, 64 KB writes | 1000 MB/s | 133 MB/s | 992 MB/s |
| 1 MB messages over TLS | 335 MB/s | 1.3 MB/s | 244 MB/s |
| raw TLS echo, 64 KB writes | 335 MB/s | 3.0 MB/s | 327 MB/s |
| 64 B messages over TLS, bare socket | — | 15k msg/s | 65k msg/s |

What the payload paid for, per MB, before and after: `Buffer.set` 319 ms →
0.5 ms; `concat`/`copy`/`Buffer.from(buf)` 8–9 ms → 0.3–0.5 ms;
`toString('utf8')` 13 ms → 3.7 ms; masking 115 ms in JS → native. Three
changes did it: the byte operations on views are `memcpy` (sockets send
straight from a view's bytes, the codecs read raw bytes, well-formed UTF-8
becomes a string by one copy); `TypedArray.set` from a view of the same
kind is one move; and the `bufferutil` and `utf-8-validate` modules exist as
built-ins over two natives, so `ws` — which asks for them by name — masks
and validates natively. The `WebSocket` global uses the same natives.

What is left is not about buffers, and the sampling profiler says where
it is. Small messages: the bare socket layer alone round-trips 86k/s (node
96k), so the rest is `ws`'s frame parser, stream and event machinery run
per message by the interpreter, where a call is ~90 ns and a view ~300 ns
against node's 5 and 34. Writes between `cork()` and `uncork()` now go out
as one, and small queued pieces are joined before a send (each frame was
two system calls); that and a lighter view (its layout in fields, one
hidden property instead of four) took the rate from 16.7k to 19.2k. A
leaner codec in the global is the next lever; a native frame-header
parser after that. TLS, measured 2026-09-27: over 95% of the samples were
in the cipher — a bit-sliced AES and a bit-at-a-time GHASH multiply. On
2026-09-28 the vendored TLS library gained the processor's AES and
carry-less multiply instructions, which took the raw TLS echo from 3 to
107 MB/s; the profile then showed half the time in `tls_read`, which
shifted the remaining plaintext down after every 16 KB handed out — a
quadratic cost on a large accumulation. It keeps a read offset now and
reads straight into the Buffer it returns, up to 64 KB a call: 327 MB/s,
level with node, and the profile is cipher 40%, system calls and copies
30%, record handling 20%.

Two socket bugs the speed exposed, fixed with it: a socket closed on the
peer's EOF while its write queue still held data (bytes lost once queues
grew), and an EOF that stayed readable was read — and `'end'` emitted —
again and again. Both sockets now stop reading at EOF, flush, then close.

## Validation

Every diff test byte-identical to Node; `--gc-stress` over the new
scripts; the `ws` echo as a manual acceptance run; existing `net`, `http`,
`https` and `fetch` diff tests unchanged; no start-up cost for scripts that
never mention `WebSocket` (lazy global); `bench` unaffected.

## Risks and open points

- The handoff happens inside the `'data'` emit that completed the head.
  The parser's listeners must be removed before it returns, and `buf`
  must be handed as `head` and then dropped, or the next chunk is seen
  twice.
- Node's client is a different implementation; error messages and the
  `error` event's details differ. The diff tests print only what the
  standard specifies: `code`, `reason`, `wasClean`, `readyState`.
- `binaryType` defaults to `'blob'` in Node; scripts that assume
  `ArrayBuffer` without setting it are wrong there too. Matching Node is
  the point.
- The close timeout (Node waits a bounded time for the peer's close frame,
  then destroys the socket) must not keep the process alive past what
  Node does; the reactor's ref/unref covers it.
- The `TLSSocket` write queue changes every TLS write, HTTPS responses
  included. The existing `https` and `fetch` diff tests and the TLS
  benchmarks must stay unchanged; a response that fits in one write must
  still go out in one.
- Size: I1 ~200 lines, I2 ~80 plus ~100 for the `TLSSocket` shape and write
  queue, I3 ~500–600 of JS plus ~80 for `Blob`, I4 ~40, plus tests — the
  shape of M33.

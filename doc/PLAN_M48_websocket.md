# M48 — WebSocket

Status: scoped 2026-09-27, not started.

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

## Where things stand (measured 2026-09-27, Node 22.16)

`ws` 7.5.10 under tsmc: fails at `require('url')`. With `url` shimmed it
gets as far as the handshake, then dies on `http.STATUS_CODES[426]` being
undefined. Past that, both sides need the `'upgrade'` event, which does
not exist.

Already present: SHA-1 (the accept key for the RFC 6455 sample matches),
base64, Buffer big-endian accessors, `crypto.randomBytes`, lazy globals
(`Headers`, `EventTarget`, ...), `EventTarget`/`Event`/`DOMException`,
`tls.connect` and `https.createServer` for `wss:`, `socket.setNoDelay`,
`stream.Duplex`, `TextDecoder` with `fatal`, `http.STATUS_CODES` (short).

Missing: `WebSocket`, `MessageEvent`, `Blob`, `CloseEvent` (Node 22 has no
global either, but the close event must carry `code`/`reason`/`wasClean`),
`require('url')`, the upgrade events, `socket.unshift`, streaming zlib.

`TLSSocket` (the socket of an `https` server or a `wss:` client) is further
behind than `net.Socket`: no `unshift`, `cork`/`uncork`, `pause`/`resume` or
`_writableState`, and no write queue. `write` hands the bytes to
`__tls_write` at once, always returns `true` and never emits `'drain'`;
ciphertext the socket does not take is buffered without limit, and a failed
`__tls_write` ends the loop with the rest of the buffer dropped and no error.
That is enough for one HTTP response; a long-lived stream is not safe on it.

## Design

### 1. The upgrade seam in `http` (the one structural change)

**Server.** In `serveConnection`, once the head is parsed: if the request
carries `Upgrade:` and `Connection: upgrade` and the server has an
`'upgrade'` listener, the parser steps aside — clear the deadline, remove
the `data`/`end`/`close` listeners it installed, mark the connection as
handed over, and `emit('upgrade', req, socket, head)` where `head` is
whatever arrived after the request head. Those bytes travel only as
`head`, never as a later `'data'`. No listener: the socket is destroyed,
as in Node. `req` is an `IncomingMessage` with no body.

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

- **I1 — `url` module + full `STATUS_CODES`.** `test/diff/url_module.js`:
  `parse`/`format`/`resolve`/`fileURLToPath`/`pathToFileURL` over a fixed
  list of inputs, vs Node.
- **I2 — the upgrade seam + `socket.unshift`.** `test/diff/http_upgrade.js`:
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
- **I3 — `WebSocket` + `MessageEvent` + `Blob`.** `test/diff/websocket.js`:
  since Node core has no server, the test carries a small frame server on
  an `http` `'upgrade'` listener, and the same script runs on both
  runtimes. Cases: text and binary echo; a 70 KB message (16-bit length)
  and a 200 KB one (64-bit); a fragmented message from the server; a
  server ping (pong observed server-side); close with code and reason,
  `wasClean` true; a wrong accept key → `error` + `1006`; invalid UTF-8
  → `1007`; both `binaryType` values; event order (`open` before any
  `message`, `close` last); `readyState` at each step; `bufferedAmount`
  back to 0 after the flush. All under `--gc-stress`.
- **I4 — `wss:`.** `test/diff/websocket_tls.js` over `https.createServer`
  with the existing `test/diff/https_server.*.pem` fixture and
  `process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'` set by the script,
  which both runtimes read at connect time. Both ends run in tsmc, so the
  test covers the server side of `wss:` (frames over the `TLSSocket` the
  `'upgrade'` hands over) as well as the client. If Node's client turns out
  not to honour it, the test moves to `test/tls/` (manual). A connection
  to a public echo endpoint stays manual, in `test/tls/`, not gated.

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

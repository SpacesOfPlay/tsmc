# PLAN M33 — `http` (client + server), then `fetch`

Stage 3 of `doc/DESIGN_networking.md`. Plaintext HTTP/1.1 on the `net`
reactor. Pure JS (no new native code) — `http` is a JS-source module over
`net` + `EventEmitter`, like `stream`.

TLS/`https` is now unblocked (the minc generic-param fix landed, so the
vendored picotls co-compiles) but is a separate milestone; this one is
plaintext.

## Increments

1. **`http` module (this increment).** `src/node_http.mc` (JS-source):
   - Server: `http.createServer(handler)` → `Server` over `net.Server`;
     parses request line + headers + body (Content-Length); emits
     `'request'(req, res)`. `IncomingMessage` (req) streams `'data'`/
     `'end'`. `ServerResponse`: `writeHead`/`setHeader`/`write`/`end`,
     emits an HTTP/1.1 response with Content-Length + `Connection: close`.
   - Client: `http.request(opts[,cb])` / `http.get` → `ClientRequest`
     over `net.connect`; writes the request, parses the response
     (Content-Length, chunked, or until-EOF) into an `IncomingMessage`
     emitted as `'response'`.
   - Verify with a loopback diff test vs Node (`test/diff/http.js`):
     GET + POST echo, status/headers/body — deterministic output (no
     Date/port printed).
2. **`fetch` + `Headers`/`Request`/`Response`** (next increment) — global,
   Promise-based, over the `http` client.

## Notes / first-cut simplifications

- Responses are buffered and sent with Content-Length (no streaming
  chunked *encoding* on the server yet); the client *decodes* chunked.
- `Connection: close` per request (no keep-alive pool yet).
- CR/LF are built with `String.fromCharCode` — minc processes `\r`/`\n`
  escapes in string literals, so the embedded JS avoids backslashes.

## Out of scope

- `https`/TLS (separate milestone, now unblocked).
- Keep-alive agent/pool, HTTP/2, trailers, Expect/continue, upgrades.

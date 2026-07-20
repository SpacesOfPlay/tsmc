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

## Shipped

Both increments landed, byte-identical to Node, `--gc-stress` clean:

1. **`http`** — `src/node_http.mc`; `test/diff/http.js` (GET 404 + POST
   echo), 100 KB POST verified.
2. **`fetch`** — `src/node_fetch.mc` (internal `_fetch` module) exposing
   `fetch`/`Response`/`Headers`-like, over the `http` client + global
   `URL`. Installed as a **lazy native global** in `module_run_entry`
   (`nat_fetch` forwards to the JS impl on first call, so non-fetching
   scripts pay nothing). `res.status`/`ok`/`headers.get`/`text()`/`json()`
   work; `test/diff/fetch.js` (GET/JSON/POST) matches Node.

Deviations: `fetch` is installed after the `globalThis` snapshot, so bare
`fetch(...)` works but `globalThis.fetch` is not populated (minor).
`https:` URLs reject with a clear TypeError until TLS lands. `Headers`/
`Request`/`Response` are not yet globals (the impl uses them internally;
`fetch` returns a `Response`).

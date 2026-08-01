# serve — an HTTPS content server on tsmc

A small content server written in TypeScript and run directly by `tsmc`:
Markdown renders to HTML, everything else is served as-is, with SHA-256 entity
tags, conditional requests, gzip, and a directory index.

```
cd examples/serve
npm install
../../build/tsmc serve.ts              # https://127.0.0.1:8443
../../build/tsmc serve.ts --http       # plain HTTP, no certificate needed
```

Options: `--root DIR --port N --host H --http --cert FILE --key FILE`.

Reaching the TLS port over plain `http://` answers with a readable 400 and a
link to the right URL, rather than the blank error a browser gets when a TLS
server just hangs up on it. That reply necessarily goes out in the clear —
there is no session to encrypt it with — and the server supplies it through
the `plaintextResponse` option, which is a tsmc extension. Without it the
connection simply closes, which is what node does.

The certificate is self-signed, so a browser shows a warning on first visit —
click through it ("Advanced" → "Accept the Risk and Continue" in Firefox). Until
you do, the browser aborts the handshake and the server logs a line like
`tls: TLS error: peer alert: bad certificate`; that is the browser declining an
untrusted certificate, not a handshake fault. A client told to trust the file
validates it fully:

```
curl --cacert serve.cert.pem https://localhost:8443/
```

## A certificate browsers do not warn about

The warning is a trust decision, not a defect, so the fix is to make the
issuer trusted. `make-local-cert.sh` / `make-local-cert.ps1` creates a local
certificate authority and a server certificate signed by it, in `local/`
(gitignored — it holds private keys):

```
./make-local-cert.sh                    # or: .\make-local-cert.ps1
../../build/tsmc serve.ts --cert local/server.cert.pem --key local/server.key.pem
```

Then trust `local/ca.cert.pem` **once**. On Windows, for Chrome, Edge and
anything else using the system store:

```
certutil -user -addstore Root local\ca.cert.pem      # remove: -delstore
```

Firefox keeps its own trust store, so it needs the certificate imported under
Settings → Privacy & Security → Certificates → View Certificates →
Authorities → Import, ticking "Trust this CA to identify websites".

[mkcert](https://github.com/FiloSottile/mkcert) does all of that in one step
and handles Firefox's store for you, if you would rather not do it by hand:

```
mkcert -install && mkcert localhost 127.0.0.1 ::1
```

A CA rather than a self-signed certificate because a browser can only be told
to trust an *issuer*: a self-signed certificate is its own issuer, so trusting
it means trusting that exact file, and the trust has to be redone every time
the certificate is reissued. A CA is trusted once.

**This is a trust-store change on your machine.** Any certificate that CA
signs will be trusted by everything using that store, so keep `local/ca.key.pem`
to yourself and remove the CA when you are done with it.

## A certificate from a public CA

`--cert` accepts a chain, so a `fullchain.pem` from Let's Encrypt (or any
public CA) works as-is — the leaf and its intermediates are all presented,
which is what lets a client build a path to a root it already trusts.

```
certbot certonly --standalone -d example.com --key-type ecdsa
tsmc serve.ts --host 0.0.0.0 --port 443 \
  --cert /etc/letsencrypt/live/example.com/fullchain.pem \
  --key  /etc/letsencrypt/live/example.com/privkey.pem
```

Get the certificate with whatever ACME client you like — certbot, lego,
acme.sh — and point the two flags at what it writes. Worth knowing before
running this anywhere real:

- **Renewal restarts the server.** The certificate is read once at startup, so
  a renewal (every 60 days, for a 90-day certificate) needs a restart to take
  effect. Run it under something that will do that.
- **One certificate per listener.** There is no SNI-based selection, so one
  process serves one certificate.
- **No ALPN.** A browser offering `h2,http/1.1` gets no ALPN extension back
  and falls back to HTTP/1.1, which is what this server speaks anyway.
- **TLS 1.3 only**, X25519, AES-128-GCM. Current browsers are fine; old
  clients and some health-check tooling will not connect at all.

## What it exercises

Three things at once, which is the point of the example:

- **TypeScript, executed directly.** No build step, no type-checker. The
  annotations, interfaces and the `Outcome` enum are handled by tsmc itself.
- **Real npm packages.** `markdown-it` renders the Markdown (with `linkify`
  turning bare URLs into links) and `js-yaml` parses the front-matter. Both
  are CommonJS, imported from ES modules with `import`, and resolve out of
  `node_modules` unmodified.
- **TLS 1.3 terminated by tsmc.** The HTTPS listener runs on the vendored
  picotls stack — the handshake, the certificate signature and the record layer
  are all tsmc's own.

Along the way it uses `fs`, `path`, `crypto` (SHA-256), `zlib`, `buffer`,
`http`/`https`, and the event loop.

## Checking it

`check.cjs` drives a running server through a fixed request list and prints a
normalised transcript — status, the headers the server controls, body length
and hash. Bodies are hashed rather than printed so the output is stable.

```
../../build/tsmc serve.ts --http --port 8099 &
node check.cjs 8099            # or: ../../build/tsmc check.cjs 8099
```

The transcript over `--http` and over TLS is byte-identical, which is the
property worth checking after any change to either.

Covered: conditional requests (matching, non-matching and `*`), gzip
negotiation, Markdown, nested Markdown, a directory index, a static asset,
`HEAD`, a rejected method, a miss, and four path-traversal attempts including
percent-encoded forms.

## Shape of the thing

| file | role |
|------|------|
| `serve.ts` | argument parsing, request handling, the listener |
| `router.ts` | URL → path, and the traversal guard |
| `render.ts` | Markdown + front-matter → HTML, directory index |
| `respond.ts` | entity tags, conditional requests, compression |
| `mime.ts` | extension → content type |
| `types.ts` | the `Outcome` enum |
| `check.cjs` | transcript driver |
| `content/` | demo corpus |

## Limits worth knowing

- **The certificate is a demo.** `serve.cert.pem` is self-signed, labelled
  `DEMO ONLY, do not reuse`, and its key is committed. Regenerate before doing
  anything real with it.
- **Whole files only.** There is no `fs.createReadStream` and `zlib` is
  sync-only, so a response body is read and compressed entirely in memory.
  `MAX_BYTES` (8 MB) refuses anything larger rather than pretending to stream.
- **Timestamps are UTC.** tsmc keeps every date in UTC and
  `getTimezoneOffset()` is always 0, which is correct for `Last-Modified` and
  wrong for anything meant to read as local time.
- **No keep-alive.** Responses close the connection.

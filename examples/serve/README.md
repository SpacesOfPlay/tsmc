# serve — an HTTPS content server on tsmc

A small content server written in TypeScript and run directly by `tsmc`:
Markdown renders to HTML, everything else is served as-is, with SHA-256 entity
tags, conditional requests, gzip, and a directory index.

```
cd examples/serve
npm install
../../build/tsmc serve.cts              # https://127.0.0.1:8443
../../build/tsmc serve.cts --http       # plain HTTP, no certificate needed
```

Options: `--root DIR --port N --host H --http --cert FILE --key FILE`.

The certificate is self-signed, so a browser shows a warning on first visit —
click through it ("Advanced" → "Accept the Risk and Continue" in Firefox). Until
you do, the browser aborts the handshake and the server logs a line like
`tls: TLS error: peer alert: bad certificate`; that is the browser declining an
untrusted certificate, not a handshake fault. A client told to trust the file
validates it fully:

```
curl --cacert serve.cert.pem https://localhost:8443/
```

## What it exercises

Three things at once, which is the point of the example:

- **TypeScript, executed directly.** No build step, no type-checker. The
  annotations, interfaces and the `Outcome` enum are handled by tsmc itself.
- **Real npm packages.** `markdown-it` renders the Markdown (with `linkify`
  turning bare URLs into links) and `js-yaml` parses the front-matter. Both
  resolve out of `node_modules` unmodified.
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
../../build/tsmc serve.cts --http --port 8099 &
node check.cjs 8099            # or: ../../build/tsmc check.cjs 8099
```

The transcript over `--http` and over TLS is byte-identical, which is the
property worth checking after any change to either.

Covered: conditional requests (matching, non-matching and `*`), gzip
negotiation, Markdown, nested Markdown, a directory index, a static asset,
`HEAD`, a rejected method, a miss, and four path-traversal attempts including
percent-encoded forms.

## Why the files are `.cts`

`.ts` is treated as an ES module, and tsmc's ESM resolver does not search
`node_modules` for bare specifiers yet — so a `.ts` file cannot `import` an npm
package today. `.cts` is Node's spelling for CommonJS TypeScript and gets both
the type syntax and `require`, so that is what the example uses.

The same constraint means no `import` syntax at all in these files, including
`import type` and `export`: any of them marks the file as ESM. Interfaces are
therefore declared in the file that uses them, and modules end with
`module.exports`.

## Shape of the thing

| file | role |
|------|------|
| `serve.cts` | argument parsing, request handling, the listener |
| `router.cts` | URL → path, and the traversal guard |
| `render.cts` | Markdown + front-matter → HTML, directory index |
| `respond.cts` | entity tags, conditional requests, compression |
| `mime.cts` | extension → content type |
| `types.cts` | the `Outcome` enum |
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

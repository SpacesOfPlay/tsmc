# M19 — `URL` / `URLSearchParams`

WHATWG globals (not modules — like `Buffer`/`process`), among the most
common APIs in real code: parsing URLs and query strings.

## `URLSearchParams` (full)

Backed by an ordered list of `[name, value]` string pairs (a hidden JS
array). Constructed from a query string (`"a=1&b=2"`, leading `?`
stripped), a `[[k,v],…]` array, a plain object, or another
`URLSearchParams`.

- `get`, `getAll`, `has`, `set`, `append`, `delete`, `sort`, `size`,
  `toString` (application/x-www-form-urlencoded: space→`+`, percent-encode
  outside `A-Za-z0-9*-._`), `forEach(value,name,this)`.
- Iterable: `keys()`, `values()`, `entries()`, and `Symbol.iterator`
  (= entries) via the shared index-iterator, so `for (const [k,v] of sp)`
  works.

## `URL` (practical parser)

`new URL(input)` and `new URL(input, base)`. Parses
`scheme://[user[:pass]@]host[:port][/path][?query][#hash]` and resolves
common relative inputs against a base (absolute-path, relative-path with
`.`/`..`, query-only, hash-only, protocol-relative, or a fully absolute
input that ignores the base).

- Read properties: `href`, `protocol` (with `:`), `username`, `password`,
  `host` (`hostname:port`), `hostname`, `port`, `pathname`, `search`,
  `hash`, `origin`, and `searchParams` (a `URLSearchParams` over the
  query). `toString()` / `toJSON()` return `href`.
- Default-port elision for `http`(80)/`https`(443)/`ws`(80)/`wss`(443)/
  `ftp`(21) in `host`/`origin`, matching Node.

## Not doing (documented)

- **Live setters** — properties are parsed once at construction; assigning
  `url.pathname = …` does not rebuild `href`, and mutating `searchParams`
  does not update `.search`. (Read/parse is the dominant use.)
- **Full WHATWG conformance** — IDN/punycode, percent-encoding
  normalization of the path, Windows `file:` drive quirks, and the
  special-scheme state-machine edge cases are approximated, not spec-exact.
- **`URL.canParse` / `URL.createObjectURL`** and the legacy `url` module
  (`url.parse`, `url.format`).

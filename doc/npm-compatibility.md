# npm package compatibility

tsmc runs `.js`/`.ts` files Bun-style and resolves `node_modules` with the
CommonJS + ESM algorithms (`package.json` `main`/`exports`, the
`node_modules` walk), so many pure-JavaScript npm packages run unmodified.
This page is an **empirical** list: every entry below was actually executed
under tsmc and its output compared byte-for-byte against Node. It is a
snapshot, not a guarantee — see [Reproducing](#reproducing) to re-run it.

> The gate is not "pure JS vs uses Node APIs" — most of the implemented
> `node:` core modules work. It's **which language/global corners a package
> touches**. The rules of thumb below predict this well.

Last run: 2026-07-22, against a local dev build of `tsmc`.

## Works

Confirmed running with output identical to Node.

### Utility & data
| package | notes |
|---|---|
| `ms@2.1.3` | time-string parse/format |
| `bytes@3.1.2` | byte-size parse/format |
| `deepmerge@4.3.1` | recursive object merge |
| `classnames@2.5.1` | conditional class strings |
| `clsx@2.1.1` | conditional class strings |
| `escape-string-regexp@4.0.0` | regex metacharacter escaping |
| `eventemitter3@5.0.1` | event emitter |
| `pino-std-serializers@7.0.0` | log serializers (symbol-keyed properties) |
| `fast-deep-equal@3.1.3` | recursive deep equality |
| `fast-json-stable-stringify@2.1.0` | stable JSON serialization |
| `immer@10.1.1` | immutable updates via Proxy (object **and array** drafts) |
| `bignumber.js@9.1.2` | arbitrary-precision decimals |
| `decimal.js@10.4.3` | arbitrary-precision decimals |
| `chalk@4.1.2` | terminal string styling (all color models + chaining) |
| `ramda@0.30.1` | functional utilities (incl. `pipe`/`compose`/`curry`) |

### IDs
| package | notes |
|---|---|
| `uuid@9.0.1` | v4 uses the implemented `crypto` |
| `nanoid@3.3.7` | uses `crypto.randomFillSync` |

### Text & strings
| package | notes |
|---|---|
| `he@1.2.0` | HTML entity encode/decode |
| `strip-ansi@6.0.1` | remove ANSI escape codes |
| `pluralize@8.0.0` | English pluralization |
| `camelcase@6.3.0` | case conversion (regex `\p{…}` property escapes) |
| `dedent@1.5.3` | template-literal dedent |

### Parsing & config
| package | notes |
|---|---|
| `js-yaml@4.1.0` | YAML parse/dump |
| `json5@2.2.3` | JSON5 parse |
| `ini@4.1.3` | INI parse/stringify |
| `query-string@7.1.3` | URL query parse/stringify |

### Templating & markup
| package | notes |
|---|---|
| `mustache@4.2.0` | logic-less templates |
| `marked@12.0.2` | Markdown → HTML (uses private class methods) |
| `markdown-it@14.1.0` | Markdown → HTML (plugin architecture) |

### Validation & versioning
| package | notes |
|---|---|
| `validator@13.12.0` | string validators (isEmail, isUUID, …) |
| `semver@7.6.3` | semantic-version compare/range |

### Dates
| package | notes |
|---|---|
| `date-fns@3.6.0` | date math + formatting (no `Intl`) |
| `dayjs@1.11.13` | date library |

### Numbers
| package | notes |
|---|---|
| `big.js@6.2.2` | arbitrary-precision decimals |

### Terminal color
| package | notes |
|---|---|
| `picocolors@1.0.1` | ANSI color strings |
| `kleur@4.1.5` | ANSI color strings |
| `colorette@2.0.20` | ANSI color strings |
| `ansi-colors@4.1.3` | ANSI color strings (chainable) |

## Does not work (yet)

Grouped by the blocker, so you can predict others. "Refused by design"
means tsmc intentionally does not support the feature; the rest are gaps.

| package(s) | blocker |
|---|---|
| `lodash`, `qs` | **Dynamic code** — `new Function(...)` / `eval` are refused by design (no runtime code generation). |

Every package in the probe matrix that *can* run now does; the two above
are blocked by a deliberate policy rather than a missing feature.

## Will it work? Rules of thumb

**Likely works**
- Small, pure-JS utilities: string/number/date/collection helpers, config
  and data-format parsers (YAML/JSON5/INI/query-string), ANSI color,
  templating, validators.
- Anything whose runtime touches only implemented globals (`Buffer`,
  `TextEncoder`/`Decoder`, `URL`, typed arrays, `Map`/`Set`, `Promise`,
  `structuredClone`) and the implemented `node:` core modules (`fs`, `path`,
  `os`, `events`, `stream`, `util`, `crypto` (sha256/random*), `zlib`,
  `net`/`http`/`https`/`tls` clients, `url`).

**Likely fails**
- **Native addons** (`.node` / N-API): `sharp`, `better-sqlite3`, `canvas`,
  native `bcrypt`, etc. — unsupported outright.
- **Native addons and runtime code generation** remain the two hard walls;
  see the table above. `Proxy` is otherwise broadly supported, including
  mutating array methods through a proxy receiver (`immer`'s array drafts
  run), so Proxy-based reactivity and immutability layers are worth trying.
- **Runtime code generation**: anything calling `eval` or `new Function`
  (many template compilers, `ajv`, `lodash`'s root detection).
- **Heavier crypto/auth**: only `crypto.createHash('sha256')`,
  `randomBytes`, `randomFillSync`, `randomUUID` exist — no HMAC, ciphers, or
  sign/verify, so `jsonwebtoken`, native `bcrypt`, `passport` won't run.
- **`Intl`-dependent** i18n/formatting.

**Not implemented core modules:** `child_process`, `worker_threads`,
`cluster`, `dgram`, `dns` (module), `readline`, `vm`, `perf_hooks`,
`async_hooks`. No `Intl`, `WeakRef`, `FinalizationRegistry`, or
`setImmediate`. `fetch` works, as do the `Headers`/`Request`/`Response`
globals. HTTP is client + server; HTTPS is client, plus a server with an
**ECDSA-P256** certificate (`https.createServer({cert, key})` — RSA and
Ed25519 server certs are not supported).

## Reproducing

The probe is `tools/npm_compat_probe.js`. In a scratch directory:

```
npm init -y
npm install <the versions listed above>
node   tools/npm_compat_probe.js > node.txt
tsmc   tools/npm_compat_probe.js > tsmc.txt
# a package "works" only if its line matches between the two files
```

Each package is exercised with a real call (not just `require`), and a
package counts as working only when tsmc's output equals Node's. A package
that loads but returns wrong output is **not** listed as working — that bar
matters, since a silently wrong result is worse than a clean failure.
Add a line to the probe to test another package.

See also the `npm-package-compat` project memory for the running list of
which gaps have since been closed (e.g. the `arguments` object, which
unblocked `js-yaml` and `validator`).

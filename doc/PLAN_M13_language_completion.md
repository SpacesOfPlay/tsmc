# M13 — language-surface completion

Deferred ES features that the conformance sweep (M11) surfaced. Each
lands one at a time: plan section below, then implementation, tests, and
a green suite before the next. Ordered easiest-first.

1. **Tagged templates** — parser already builds the node; wire raw
   strings and compile the call.
2. **Private class fields** (`#x`) — parser + lowering + per-instance
   storage.
3. **Regex named groups** (`(?<n>…)`, `$<n>`, `.groups`) — regex engine.
4. **BigInt** — a new primitive type; needs a `DESIGN_bigint.md` first
   (value representation is cross-cutting).

---

## 1. Tagged templates — DONE

`` tag`q0${e0}q1${e1}q2` `` calls `tag(strings, e0, e1)` where `strings`
is `["q0","q1","q2"]` (cooked) carrying a `raw` array of the unescaped
source quasis.

Current state: the parser already produces `N_TAGGED_TEMPLATE`
(`a` = tag expr, `b` = `N_TEMPLATE`); only the compiler is missing it,
so it falls through to "expression not supported yet". The lexer keeps
the **cooked** quasi in `Token.text`; the **raw** source is
`src[a..b)` inside `scan_template`, currently discarded.

### Approach

- **Lexer** (`scan_template`): also store the raw view in the token's
  free `aux` field: `t.aux = lx_view(lx, a, b)`.
- **Parser** (`parse_template`): copy that onto each `N_TEMPLATE_ELEM`'s
  free `aux` field (`q.aux`), for the head/full quasi and each
  middle/tail quasi.
- **Compiler** (`N_TAGGED_TEMPLATE`): mirror `N_CALL`'s callee/`this`
  setup — a member tag (`obj.tag`) keeps its receiver via `OP_GETMETHOD`,
  a plain tag pushes `OP_UNDEF` for `this`. Then build the strings
  object and call:
  - push cooked quasi consts, `OP_NEWARR n` → the strings array;
  - `OP_DUP`, push raw quasi consts, `OP_NEWARR n`, `OP_SETPROP "raw"`,
    `OP_POP` → leaves the strings array with `.raw` set;
  - compile each substitution expression as the remaining args;
  - `OP_CALL` with `argc = 1 + n_substitutions`.

### Not doing (documented)

- The strings object is built fresh per evaluation (no per-call-site
  caching) and is not frozen. Both are observable only by identity
  (`` t`x` === t`x` ``) or mutation of `strings`, which real tags don't do.

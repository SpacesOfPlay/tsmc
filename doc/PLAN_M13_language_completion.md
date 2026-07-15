# M13 — language-surface completion

Deferred ES features that the conformance sweep (M11) surfaced. Each
lands one at a time: plan section below, then implementation, tests, and
a green suite before the next. Ordered easiest-first.

1. **Tagged templates** — DONE.
2. **Private class fields** (`#x`) — DONE.
3. **Regex named groups** (`(?<n>…)`, `$<n>`, `.groups`) — DONE.
4. **BigInt** — DONE (see `DESIGN_bigint.md`). Arbitrary-precision
   integer primitive: literals, `+ - * / % **`, comparison/equality
   across BigInt/Number, `typeof`, ToBoolean/ToString, `Number()`,
   `BigInt()`, `.toString()`. Bitwise operators, `asIntN`/`asUintN`,
   and non-decimal `toString` radices remain deferred.

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

---

## 2. Private class fields (`#x`) — DONE

`class C { #x = 5; #m() {…}; get() { return this.#x; } }`. The lexer and
parser already produce private names (`TOK_PRIVATE_NAME`,
`N_PRIVATE_IDENT`, `N_MEMBER` with `NF_PRIVATE`); the private text drops
the `#` (so `#x` → `"x"`). Only the compiler rejects them
("private class members are not supported yet").

### Approach — mangled non-enumerable key

Store each private name under the atom `"%#" + name` (e.g. `#x` →
`"%#x"`). The `%` prefix makes it non-enumerable through the existing
`vm_enumerable_key` rule (so it never shows in keys/`for-in`/JSON), and
the `#` keeps it clear of the engine's other `%`-internal props. All
private access routes through one mangling helper, with `prop_key_const`
learning `N_PRIVATE_IDENT`:

- **Field** `#x = init` — already classified as an instance field;
  `emit_field_inits` writes `this["%#x"] = init` via `prop_key_const`.
- **Method** `#m() {}` — installed on the prototype under `"%#m"` (kept
  reachable through the proto chain for `this.#m()`).
- **Read/write** `this.#x` — the `N_MEMBER`/assignment paths emit
  `OP_GETPROP`/`OP_SETPROP` on `"%#x"`.

### Not doing (documented)

Not spec-strict privacy: the key is a mangled string, so there is no
per-class brand — two classes' `#x` share a key, `#x in obj` is a plain
own-key test, and accessing a private field on a foreign instance reads
`undefined` instead of throwing. Real single-class encapsulation works;
these are rare cross-class edges.

---

## 3. Regex named groups (`(?<n>…)`, `$<n>`, `.groups`) — DONE

`/(?<y>\d+)-(?<m>\d+)/` captures numbered groups as today, plus a
`groups` object (`{ y, m }`) on the match, `$<name>` in string
replacements, and a trailing `groups` argument to a replacer function.

Current state: the engine parses numbered/non-capturing/lookahead groups
(`RN_GROUP`, `RN_NCGROUP`, `RN_LOOK`) but `(?<…` falls through to an
error. Match results and `replace` handle numbered groups only.

### Approach

- **Engine** (`regex.mc`): in `parse_atom`, recognize `(?<name>` (but
  not `(?<=`/`(?<!`, which stay unsupported lookbehind). It is an
  ordinary capturing group — assign the next group index — plus record
  `name → index`. Store a `str* group_names` (size `n_groups+1`,
  index → name or empty) on `RegexProg`; expose `regex_has_named` and
  `regex_group_name(prog, gidx)`.
- **Match result** (`regexp_exec_impl`): always set `result.groups` —
  `undefined` when there are no named groups, else a null-prototype
  object mapping each name to its capture (or `undefined` if the group
  didn't participate). Numbered access (`m[1]`) is unchanged.
- **String replacement**: `$<name>` resolves to the named group's
  capture alongside the existing `$1`/`$&`/`` $` ``/`$'` handling.
- **Replacer function**: when the pattern has named groups, pass the
  `groups` object as the final argument after `offset`, `string`.

### Not doing

Lookbehind (`(?<=…)`, `(?<!…)`) stays unsupported — a separate engine
feature.

# PLAN M36 — regex Unicode property escapes (`\p{…}` / `\P{…}`)

**Status: complete.** All three increments landed. General categories
(short/long/group, with the `gc=` spelling), the nine binary properties,
and — see the amendment in §1 — `Script=` all match node byte for byte
(`test/diff/regex_uniprop.js`); unsupported names raise `SyntaxError`.
`camelcase` now matches node, which closes the last real-package gap in
`doc/npm-compatibility.md` (`lodash`/`qs` remain blocked only by the
deliberate refusal of `eval`/`new Function`). Suite green: 58 tests, 85
gc-stress scripts, full node diff. Still out of scope:
`Script_Extensions=`, Script value short aliases, the remaining binary
properties, and `v`-mode set notation — each a loud error, never a
silent mismatch.

Closes the last remaining real-package gap in `doc/npm-compatibility.md`.
Today `\p{…}` is worse than merely missing: in a character class it
compiles **silently** to the literal set `{p, {, L, u, }}`, so
`/[\p{Lu}]/u.test('A')` is `false` while `.test('p')` is `true`. A regex
that quietly matches the wrong characters is the failure mode this
project treats as most serious, and it is exactly why `camelcase`
returns `foo-bar` instead of `fooBar`.

---

## 1. Goal / non-goal

**Goal.** Support `\p{…}` and `\P{…}` in `u`-mode patterns, in both atom
position (`/\p{Lu}/u`) and inside character classes (`/[\p{Lu}\d]/u`),
for the Unicode **general categories** and a useful set of **binary
properties**, with correct negation. An unrecognised property name is a
`SyntaxError` — never a silent literal fallback.

**Non-goal (this milestone).** `Script=` / `Script_Extensions=`
(large tables, rare in the npm code we target), the remaining binary
properties (Emoji*, Grapheme_*, Math, Dash, …), and `v`-mode set
notation. Their absence is a documented, *loud* error, not a silent
mismatch. Case-insensitive matching of `\p{…}` follows the engine's
existing ASCII-only case-fold limitation (`DESIGN_regex.md`).

> **Amended during implementation.** The "large tables" premise was
> measured and turned out false for `Script`: like general category it
> is a *partition* of the code-point space, so it run-length encodes to
> **1,701 runs over 170 values** — smaller than the 4,099-run category
> table. Since it was cheap and it was the only remaining divergence
> from node in the supported surface, `Script=` / `sc=` was folded into
> this milestone. `Script_Extensions` genuinely is different: it is
> multi-valued (13 code points differ from `Script` for Greek alone), so
> it stays out, as do Script value short aliases (`Grek`) — node
> accepts both and tsmc raises `SyntaxError`, which is the one place the
> supported surface is narrower than node's.

Also unchanged: `\p{…}` requires the `u` flag. Without `u` the escape
keeps its legacy meaning (identity escape, i.e. literal `p`), which is
what the spec mandates for non-unicode patterns.

---

## 2. Why this is small

`DESIGN_regex.md` describes a byte-oriented matcher, which would make a
code-point-indexed property test awkward — but the class path is already
code-point aware. In `u` mode `I_CLASS` decodes a whole UTF-8 sequence
and tests the resulting code point against the class's `RxRange{lo,hi}`
list (`src/regex.mc`). `\d`/`\w`/`\s` are already built by appending
ranges to a `Vec<RxRange>` and calling `register_class`.

So `\p{…}` needs no matcher work at all. It is:

1. a table mapping a property name to code-point ranges, and
2. parser wiring that appends those ranges — the same shape as
   `add_digit` / `add_word` / `add_space`.

---

## 3. Table design

Two kinds of data, generated (see §4) into `src/regex_uniprops.mc`:

**General categories — one run-length table.** The 29 two-letter
categories partition the code-point space, so a single table of runs
(`start` + category id, next run's `start` bounding it) serves every
`\p{Lu}`-style query *and* every group query (`L` = Lu|Ll|Lt|Lm|Lo,
`N` = Nd|Nl|No, and likewise M, P, S, Z, C). Measured: **4,099 runs**
for the whole space — about 20 KB as `u32 start` + `u8 cat`.
Unassigned code points are `Cn`, which makes `\p{C}` and `\P{…}` fall
out correctly without a separate gap table.

**Binary properties — one range list each.** These are not derivable
from general category (`Alphabetic` includes `Other_Alphabetic`, etc.),
so each gets its own `{lo,hi}` list. Measured range counts:
`Alphabetic` 757, `Assigned` 731, `Uppercase` 656, `Lowercase` 675,
`ID_Start` 677, `ID_Continue` 793, `White_Space` 10, `ASCII` 1, plus
`Any` (the trivial full range). ~34 KB.

Total ≈ 55 KB of static data — the same order as the bundled CA store.

**Name resolution.** Both the short and long forms resolve
(`Lu` / `Uppercase_Letter`, `N` / `Number`, `Alpha` / `Alphabetic`,
`space` / `White_Space`), as does the explicit
`\p{General_Category=Lu}` / `\p{gc=Lu}` form. Anything else is a
`SyntaxError`.

---

## 4. Generating the tables

`tools/gen_unicode_props.mjs`, run under node, emits
`src/regex_uniprops.mc` — the same pattern as `tools/gen_ca_roots.sh`
generating `src/tls/ca_roots_data.mc`.

The generator derives every table by **querying node's own regex engine**
(`new RegExp('\\p{gc=Lu}','u')` over the code-point space) rather than
parsing `UnicodeData.txt`. That keeps the generator tiny and dependency
free, and it means the tables agree by construction with the engine the
differential suite compares against. The Unicode version is therefore
node's; the generator records it in a header comment so the provenance
is not a mystery.

Surrogates (`D800–DFFF`) are handled explicitly (`Cs`) since
`String.fromCodePoint` cannot round-trip a lone surrogate through
`.test()`.

---

## 5. Increments

- **I1 — tables.** `tools/gen_unicode_props.mjs` + generated
  `src/regex_uniprops.mc`, with a lookup API:
  `uniprop_lookup(str name, Vec<RxRange>* out) -> bool` (false = unknown
  name). Unit-tested directly (spot-check known code points per
  category: `A`→Lu, `a`→Ll, `5`→Nd, `,`→Po, `À`→Lu, `Α`→Lu, `一`→Lo).
- **I2 — parser wiring.** `\p{…}` / `\P{…}` in atom position and inside
  classes; `\P` negates; unknown names raise `SyntaxError`. Replaces
  both current behaviours (the atom-position hard failure and the
  in-class silent literal fallback).
- **I3 — conformance + docs.** `test/diff/regex_uniprop.js` against
  node, `camelcase` verified end-to-end, `DESIGN_regex.md` "Deferred"
  list updated, `doc/npm-compatibility.md` updated.

Each increment builds clean, keeps the suite green (`build.ps1 test`,
including `--gc-stress`), and matches node byte-for-byte where it is
observable.

---

## 6. Pitfalls to avoid

- **Silent fallback is the bug.** Any unknown or unsupported property
  must throw, not degrade to a literal. This is the whole reason the
  milestone exists.
- **`\P{…}` negation inside a class.** `[\P{L}]` negates the property,
  which is *not* the same as negating the enclosing class
  (`[^\p{L}]`). They coincide for a single-item class but not in
  general — `[\P{L}x]` matches `x` and every non-letter.
- **Negation must be over the full code-point space**, `0…10FFFF`,
  including unassigned code points, not just the assigned ranges.
- **Class negation composition.** The existing `register_class(negate)`
  applies to the whole class; a `\P{…}` member must be materialised as
  its complement *ranges* before being appended, so the two negations
  compose correctly.
- **Non-`u` patterns must not change.** `/[\p{Lu}]/` (no `u` flag) keeps
  its legacy identity-escape meaning; only `u` mode gains the new
  semantics.

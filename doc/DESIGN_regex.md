# Regular expressions

Decision: **own backtracking engine** — pattern → node tree →
instruction array → recursive backtracking matcher. Self-contained in
`src/regex.mc`, testable without the VM.

## Byte-oriented

The matcher runs over UTF-8 bytes, consistent with the string model
(`DESIGN_string.md`): `.`, character classes, and quantifiers count
bytes, not code points. ASCII — the overwhelming majority of real
patterns — is exact. A non-ASCII literal in the pattern compiles to a
byte sequence and matches those bytes; `.` matches one byte. Case
folding is ASCII-only. This moves to code points when the string
model gains its wide representation.

## Pipeline

1. **Parse** the pattern (recursive descent) into a node tree:
   chars, `.`, classes, concatenation, alternation, the quantifiers
   (`* + ?` and `{n,m}`, greedy and lazy), capturing / non-capturing
   groups, lookahead (`(?= )` / `(?! )`), backreferences, and the
   anchors `^ $ \b \B`.
2. **Emit** a flat instruction array with patched jumps —
   `CHAR ANY CLASS MATCH JMP SPLIT SAVE BOL EOL WORDB NWORDB BACKREF
   LOOK_BEGIN LOOK_DONE`. Quantifiers lower to `SPLIT`/`JMP` loops;
   groups to `SAVE` pairs; `{n,m}` expands to mandatory copies plus
   optionals.
3. **Match** by recursive backtracking (`SPLIT` tries its first
   branch, falls through on failure; `SAVE` rolls its capture back
   when the continuation fails). A step counter bounds catastrophic
   backtracking — over the limit the attempt reports no match rather
   than hanging.

Lookahead compiles inline as `LOOK_BEGIN … LOOK_DONE`; the matcher
recurses over the body without consuming input, then jumps past it.
Positive-lookahead captures persist; negative-lookahead attempts
discard theirs.

## Flags

`i` ASCII case-fold, `m` (`^`/`$` at line breaks), `s` (`.` matches
newline). `g`/`y` are handled by the String/RegExp layer through
`lastIndex`, not the matcher.

## Deferred (diagnostics or documented gaps)

Named groups and named backreferences, lookbehind, the `u` flag's full
code-point semantics and the sticky `y` flag's full behavior.

Unicode property escapes (`\p{…}` / `\P{…}`) **are** supported in `u`
mode — see `PLAN_M36_regex_uniprops.md`. They need no matcher work:
under `u` the class instruction already decodes a whole code point, so a
property escape only has to contribute code-point ranges, exactly like
`\d`/`\w`/`\s`. The tables live in the generated `regex_uniprops_data.mc`
(general categories as one run-length table, `Script` as another, one
range list per binary property). Not supported, and raising
`SyntaxError` rather than degrading to a literal: `Script_Extensions=`,
Script value short aliases, the remaining binary properties, and
`v`-mode set notation. Backreferences to unset groups match empty
(per spec). No compiled-pattern portability concerns — progs are
owned by the VM and freed at teardown.

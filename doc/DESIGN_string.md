# String model

Decision: **immutable UTF-8 byte strings for now**, with all
length/index/slice logic routed through helpers so the storage model
can change without touching the builtin surface.

## What this means

- A JS string is a `GC_STRING` cell: one allocation, UTF-8 bytes.
  The lexer already produces (W)UTF-8; atoms, `console` output, and
  source text share the encoding, so no boundary conversions exist
  anywhere.
- `.length`, indexing, `charCodeAt`, `slice` offsets count **bytes**.
  For ASCII — the overwhelming majority of program-manipulated
  strings — this is exactly UTF-16 code-unit semantics. For non-ASCII
  content the counts diverge from JS (`"é".length` is 2 here, 1 in
  JS). Passing text *through* (concat, print, compare, JSON) is
  correct for all of Unicode; only unit-level introspection deviates.
- `toUpperCase`/`toLowerCase` map ASCII letters only.

## Why not u16 now

The meta-plan's default was u16 storage first. Overturned for M6:
every string crossing the engine boundary (lexer literals, atoms,
console, JSON text) is UTF-8, so u16 storage taxes every string with
a conversion to fix a deviation that only shows up in unit-level
introspection of non-ASCII text. The conformance milestone needs the
real model anyway — a dual representation (latin1 narrow / u16 wide,
QuickJS-style) — and doing that once, behind the helper layer this
milestone puts in place, beats doing u16-only now and dual later.

## Migration path

`string_units(s)`, `string_unit_at(s, i)`, and the slice helpers in
the builtins are the only code that interprets positions. The dual
representation adds a wide variant to the string cell and swaps these
helpers; builtins above them do not change. Tracked as an explicit
pre-conformance work item in the meta-plan (M11/M12 boundary).

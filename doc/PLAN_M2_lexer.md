# M2 — lexer

Tokenizer for the full TypeScript grammar. Deliverables: `src/lexer.mc`,
`test/unit/test_lexer.mc`.

## Shape: pull scanner with rescans

JS cannot be tokenized without parser context: `/` is division or a
regex start, `}` is a block end or a template continuation, and `>>`
must split into `>` `>` inside type argument lists. Instead of
heuristics over a pre-lexed token vector, the lexer is a pull scanner
the parser drives:

- `lexer_next` returns the next token with defaults: `/` lexes as
  division, `}` as a plain brace, `>`-family maximal munch
  (`>>>=` over `>` `>` `>` `=`).
- `lexer_rescan_regex(lx, tok)` re-lexes a `/` or `/=` token as a
  regex literal — called when the parser expects an expression.
- `lexer_rescan_template(lx, tok)` re-lexes a `}` as a template
  middle/tail — called when the parser closes a `${…}` substitution.
- `>`-splitting in type contexts is parser-side (M3): it consumes one
  `>` and re-enters the lexer at `tok.start + 1`.

Speculative parsing (arrow-function lookahead, type ambiguities) works
by saving and restoring the scan position; the lexer keeps no state
beyond it, so rewind is one assignment.

## Tokens

`struct Token { kind, start, end, newline_before, num, text, aux }`.
Spans are byte offsets. `newline_before` records a line terminator (or
a comment containing one) before the token — the parser's ASI input.

- Identifiers: ASCII `[A-Za-z_$][A-Za-z0-9_$]*`; `text` views the
  source. Keywords (reserved + TS contextual, one contiguous kind
  block) resolve via a `StrMap<i32>` built at init; the parser treats
  contextual keywords as identifiers by position. `#name` lexes as a
  private name.
- Numbers: decimal (int, fraction, exponent), `0x`/`0o`/`0b`, `_`
  separators (between digits only), `123n` as a distinct bigint kind.
  Decimal values parse via a u64 mantissa and exact powers of ten —
  correctly rounded when the mantissa fits 2^53 and the exponent is
  within ±22, approximated (≤ ~2 ulp) outside that. Legacy octal
  (`0123`, `08`) is an error.
- Strings: `'…'`/`"…"`, full escape set (`\n \x41 A \u{1F389}`),
  line continuations. Clean strings view the source; strings with
  escapes decode into lexer-owned buffers (freed by `lexer_destroy`).
  Escaped surrogate halves encode as WTF-8 pending the string-model
  milestone.
- Templates: `full` / `head` / `middle` / `tail` kinds; `text` is the
  cooked value with `\r\n` → `\n` normalization; raw text is
  recoverable from the span.
- Regex (rescan only): `text` = pattern, `aux` = flags; bracket
  classes and escapes tracked, no pattern validation here.
- Trivia: whitespace, `//` and `/* */` comments, a leading `#!` line,
  and a BOM are skipped. U+2028/2029 count as line terminators.

## Errors

All through `diag.mc` with spans; the lexer emits `TOK_ERROR` for
unterminated strings/templates/regexes and recovers per-escape (bad
escape → diagnostic, char kept) so one bad literal yields one error.

## Deferred

- Unicode identifiers and `\u` escapes in identifiers (diagnostic now).
- Correctly-rounded decimal→f64 for all inputs (Eisel-Lemire +
  bignum fallback) — own infrastructure task before conformance work.
- BigInt values (token kind exists; parser rejects until supported).

## Tests

Kind/value/span goldens for every category: maximal munch (incl.
`?.5` lexing as `?` `.5`), keyword vs identifier, all numeric forms
and their exact f64 values, escape decoding byte-for-byte, template
chains driven through rescan, regex via rescan (classes, escaped
slashes, flags), `newline_before` (incl. via block comment),
error cases produce diagnostics without hanging.

# M46 — early errors

Status: landed on main (2026-09-09), measured 2026-09-10. The suite's
language tests went from 18,817 passing to 19,457 of 21,037, and the
early-error group of the remaining failures from 831 to 215.

## Why

The language names a set of programs that must be refused before any of
them runs: the early errors. On the 2026-09-08 test262 run they were the
largest coherent failure cluster, 831 of the 2,220 remaining failures,
and every one of them was a program tsmc accepted and ran. Some of those
programs are harmless, but several hide real bugs in user code: a
`"use strict"` directive that a destructured parameter silently switches
off, a class whose second constructor quietly replaces the first, a
`super()` call in a method that was never a constructor, a label that
shadows another and sends `continue` to the wrong loop.

## The negative test tier

`test/neg/<name>.js` is a program the compiler must refuse. Its first
line is `// expect: <fragment>`; the runner in `build.mc` requires exit
code 2 and that fragment in the output (an empty fragment only requires
the exit code). The valid programs that sit right next to each rule live
in `test/diff/early_valid.js`, so a rule that overreaches shows up as a
difference from node in the same run. The tier runs inside `minc test`,
after the golden tests.

## What landed

Each rule is checked where the information exists. The parser reports
what it can see from tokens (strictness, declaration positions, escapes,
operator shapes); the compiler reports what needs scopes (names,
redeclarations, class element bodies).

**Functions and parameters.** `"use strict"` is refused in a function
whose parameters are anything but names. A rest parameter is last, with
no trailing comma. A rest element in an assignment pattern is last and
takes no default. A strict function may not be named `eval` or
`arguments`, nor bind them as parameters; its parameters are unique. A
default may not `yield` or `await`. A lexical declaration in a body may
not repeat a parameter, and one in a catch block may not repeat the
catch parameter.

**Strict-mode names.** Strict code binds neither `eval` nor `arguments`,
assigns to neither (plain, compound, logical, update and destructuring
forms alike), and uses none of `implements interface package private
protected public static let yield` as a name. The parser tracks strict
code for its own rules: a `"use strict"` prologue on a script or a
function body, and every class body.

**Declarations in single-statement positions.** `let`, `const`, `class`,
generators and async functions are refused as the body of an if, a loop
or a label. A plain function declaration is refused there in strict
code and in loops; sloppy code keeps the Annex B allowance for if bodies
and labels. A labelled function declaration is refused as the body of
an if or a loop in either mode, and hoists like an unlabelled one where
it is allowed.

**Redeclarations.** Function declarations in a block are lexical: no
`var` of the same name anywhere in the block, and no second declaration,
except that sloppy code may repeat a plain function. The clauses of a
switch share one scope for this. At the top of a function body they stay
var-like.

**Classes.** One constructor, and not an accessor, generator or async
method. No field named `constructor`, no static member named
`prototype`, no `#constructor`. A private name is declared once, except
a getter with its setter of the same placement. A field initializer or
static block mentions neither `arguments` nor a `super()` call; `super()`
belongs to a derived constructor and the arrows inside it, and `super`
takes no private name. A static block is also a boundary for `return`,
`yield`, `await` (as expression or name), labels, and `break` or
`continue` to a loop outside it. A computed instance field key is now
evaluated once, when the class is defined, in the scope around the
class; it used to run in the constructor on every construction.

**Object literals.** `__proto__` is defined at most once; `get`, `set`,
`async` and `*` must be followed by a method; a shorthand property is a
name, not a number, string or computed key; `async` and its method share
a line. A getter takes no parameters and a setter exactly one.

**Operators and chains.** A bare unary operator may not precede `**`;
`??` does not mix with `||` or `&&` without parentheses; nothing is
assigned, updated or tagged through an optional chain; `=>` stays on the
line of its parameters; `yield` and its star share a line; a label may
not repeat one that encloses it; the head of a plain for-of may not be
the bare identifier `async`.

**Lexer.** A keyword spelled with a Unicode escape is an identifier,
refused where the word could not have been one and accepted as a
property name; an escape must spell an identifier character; VERTICAL
TILDE is not one. A numeric separator may not follow a leading zero. A
line or paragraph separator ends a regular expression literal.

**Regular expression literals.** A quantifier with nothing to repeat is
refused, including a brace that forms one; a lookahead may not be
quantified under `u`; `\k` in a pattern with named groups, or under `u`,
carries a complete name; a group name is an identifier by the Unicode
tables.

## What the measurement found

Three of the new rules were refusing valid programs, 59 tests' worth, all
fixed the next day:

- A script's top level binds function declarations the way a function body
  does, not the way a block does. `function f() {} var f;` is legal there,
  and the block rule was firing on it. This was most of the 59, and it
  would have refused ordinary code.
- `let` alone at the end of a line, where a declaration cannot appear, is
  an identifier reference: semicolon insertion ends the statement. The
  error was wrong, and worse, the parse still swallowed the next line into
  a declaration, so a loop body that never runs assigned anyway.
- Only the literal spelling of `async` is barred from a for-of head. The
  check compared decoded names, so it caught `\u0061sync` too.

The lesson is that a negative test suite cannot tell you when a rule is
too eager. What caught these was diffing the new failure list against the
old one and reading every test that had started failing, positive ones
first.

A second group, about 180 tests, regressed for a different reason: they
were passing by accident. The lexer used to decode an escaped keyword into
the keyword itself, so `var \u0061wait` inside an async function failed as
a keyword misuse. Now that the lexer is right, those programs are accepted
because tsmc does not reserve `await` and `yield` in async functions and
generators, which it never did for the plain spellings either. Closing
that is the next piece of work, and it is worth about 180 tests.

## Not covered

- Annex B block-level function hoisting: `{ function f() {} }` does not
  make `f` visible outside the block, so the sloppy allowances above are
  accepted but the binding stays inside. Independent of this milestone.
- `super()` called from an arrow inside a derived constructor runs with
  the wrong `this` at run time; the early error side is right.
- A `var` that repeats a destructured catch parameter, and `for (var e
  of ...)` inside `catch (e)`, are still accepted.
- `await` and `yield` are not reserved inside async functions and
  generators, in either spelling. The largest remaining early-error group.
- The Unicode property tables are a version behind the suite, so a few
  identifier tests fail in both the plain and the escaped spelling. Two of
  them only need U+30FB and U+FF65 added to Other_ID_Continue, which
  Unicode 15.1 did; the rest need the tables regenerated.
- Escapes inside a regular expression group name are not validated.
- Object-literal methods have no `super` binding, so `super.x` there is
  refused instead of working.

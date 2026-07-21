# PLAN — the `arguments` object

**Status: implemented (I1–I3 done).** `arguments` works in ordinary
functions, is captured lexically by arrows, and is correct across
apply/call/bind, generators, and async functions. It is an unmapped
array-like object (`Object.prototype` proto, non-enumerable `length`,
iterable). `test/diff/arguments.js` matches Node byte-for-byte; the npm
matrix confirms it unblocked js-yaml and validator. Not done (own
follow-up, and the reason `Array.prototype.slice.call(arguments)` still
fails): tsmc's Array methods reject non-array `this`, so the legacy
`.call(arguments)` idiom needs array-like-receiver support — modern
`[...arguments]` / `Array.from(arguments)` work today. Also unchanged:
sloppy-mode mapped arguments and module-top-level `arguments`.

Implements the `arguments` object inside ordinary (non-arrow) functions.
Currently a bare `arguments` compiles to a global load and throws
`arguments is not defined`, which blocks a large class of transpiled npm
packages (js-yaml, validator, and much Babel output). This is a
compiler + VM feature, not a builtin.

## 1. Semantics (what we implement, and what we don't)

**In scope:**
- `arguments` is bound in every ordinary function — declarations,
  expressions, methods, generators, async functions — to an array-like
  object holding the actual call arguments (all of them, including any
  beyond the declared parameters).
- `arguments.length`, `arguments[i]`, and iteration (`for..of`,
  `[...arguments]`, `Array.prototype.slice.call(arguments)`) work.
- **Arrow functions do not bind their own `arguments`** — a reference
  inside an arrow resolves to the nearest enclosing ordinary function's
  `arguments` (lexical), exactly as arrows treat `this`.
- Built only when the function actually references `arguments`
  (detected at compile time), so functions that don't use it pay nothing.

**Out of scope (documented, not silently skipped):**
- **Mapped arguments.** We build an *unmapped* (snapshot) object: writing
  `arguments[0]` does not alias the named parameter and vice-versa. This
  is the strict-mode behavior and is what modern/transpiled code expects.
- `arguments.callee` / `arguments.caller` — throw-or-absent; almost never
  used and forbidden in strict mode.
- **Top-level `arguments`** (module or script scope, outside any function)
  stays a "not defined" free reference. Node exposes the CJS wrapper's
  five args there; that's an obscure edge we skip.

## 2. The mechanism — mirror `this`

`this` is already handled precisely the way `arguments` needs to be
(compiler.mc ~1436): a non-arrow function that is captured by a nested
arrow declares an implicit local, initialized in the prologue, which
arrows then capture as an upvalue. `arguments` reuses this shape. The one
real difference: `this` is always available in the frame (`fr.this_val`),
whereas the actual arguments are **destroyed by `normalize_args`** (it
pads/truncates the stack to exactly `n_params` before the body runs, so
surplus args are gone). So the arguments object must be **built at the
call site, before `normalize_args`, and stashed in the frame.**

Two resolution paths compose:
- **Direct use in an ordinary function** → a new `OP_ARGUMENTS` opcode
  that pushes the frame's prebuilt arguments object.
- **Use inside a nested arrow** → the enclosing ordinary function declares
  an implicit `arguments` local (prologue: `OP_ARGUMENTS; SETLOCAL`), and
  the arrow captures it as an upvalue via the existing `resolve_upval`.
  `scan_inner` already collects `arguments` into `fs.inner` when a nested
  function mentions it (via `scan_all_names`), so the existing gate works.

## 3. The arguments object shape

An **array-like object**, not a real Array (recommended):
- prototype = `Object.prototype` (so `arguments.map` is undefined and
  `Array.isArray(arguments) === false`, matching Node),
- own data properties `0..length-1` (enumerable) = the arguments,
- own `length` property (non-enumerable, so `Object.keys(arguments)` and
  `for..in` yield only the indices, and `JSON.stringify(arguments)` gives
  `{"0":..}` — matching Node),
- `Symbol.iterator` = a values iterator over `0..length` so spread and
  `for..of` work.

The `length` non-enumerability and the `Object.prototype` (not
`Array.prototype`) proto are the two details that make it match Node
rather than merely "work". Building it on a real Array would be less code
but would leak Array methods and flip `Array.isArray` — a diff-test
mismatch waiting to happen, so we don't.

Reuses existing machinery: `js_new_object(&vm.heap, vm.object_proto)`,
`js_set_prop` for indices, `props_set_desc` with the non-enumerable attr
for `length`, and the array values-iterator native for `Symbol.iterator`
(a small generic array-like iterator may be needed if the existing one
assumes real-array storage — a point to verify during I2).

## 4. File-by-file changes

- **bytecode.mc** — add `OP_ARGUMENTS` to the opcode enum (next to
  `OP_THIS`). No name table / disassembler to update.
- **vm.mc**
  - `Frame` gains `Value arguments_obj;`; GC-mark it beside `this_val`
    (~line 275) and initialize it to `undefined` in the script frame
    (~line 3046).
  - `FnTemplate` gains `bool needs_arguments;`.
  - `OP_ARGUMENTS` dispatch case: `vpush(vm, fr.arguments_obj)`.
  - **Both** JS-frame setup sites build the object before
    `normalize_args` when `ft.needs_arguments`: the `OP_CALL`/`OP_NEW`
    path (~2443) and `vm_call_stack` (~line 25, used by
    `Function.call`/`apply`/`bind` and native callbacks). Factor a
    `build_arguments(vm, argstart, argc) -> Value` helper and a shared
    frame-setup path to avoid drift.
  - **Generators / async**: `make_generator_from_call` and
    `make_async_from_call` (dispatched before the normal frame setup) must
    also build and carry `arguments_obj` into the suspended frame. This is
    the fiddliest sub-case and gets its own test.
  - GC safety: root the freshly built object across `normalize_args`
    (which may allocate a rest array) until it's stored in the frame.
- **compiler.mc**
  - `FScope` gains `bool needs_arguments;`.
  - Prologue (right after the `this` block, ~1446): if
    `!fs.is_arrow && fs.inner has "arguments"`, `declare(co, "arguments")`
    and emit `OP_ARGUMENTS; SETLOCAL; POP; (CELLIFY if captured)`; set
    `fs.needs_arguments = true`. (Serves the arrow-capture case.)
  - `emit_load_ident`: when `name == "arguments"` and no local/upval/import
    resolves, and `!fs.is_arrow && fs.parent != null` (an actual function,
    not module/script top), emit `OP_ARGUMENTS` and set
    `fs.needs_arguments = true`, instead of falling through to
    `OP_GETGLOBAL`. (Serves the direct-use case.) In an arrow the name
    always resolves via the enclosing local/upval before reaching here, so
    arrows never mis-emit `OP_ARGUMENTS`.
  - `func_compile` copies `fs.needs_arguments` onto the finished
    `FnTemplate` (extend `chunk_finish` or set `t.needs_arguments` after).
  - Guard the rare `let arguments`/param-named-`arguments` shadow: if a
    binding named `arguments` already exists, the implicit one is not
    created (a user binding wins via `find_local`); skip the prologue
    declare in that case.

## 5. Increments

1. **I1 — core path.** `OP_ARGUMENTS`, the `FnTemplate`/`Frame` fields,
   build-at-`OP_CALL`, prologue + `emit_load_ident` wiring, the array-like
   object. Covers ordinary functions and arrow capture. Diff test:
   length, indexing, surplus args, spread/iteration, `slice.call`,
   arrow-reads-enclosing, shadowing, `Array.isArray === false`,
   `Object.keys` = indices only.
2. **I2 — call-shape coverage.** `vm_call_stack` path (so
   `fn.apply(null, xs)` / `fn.call` / bound functions see correct
   `arguments`), plus generators and async functions. Diff tests for each.
3. **I3 — the payoff.** Re-run the npm matrix; js-yaml and validator
   should clear their `arguments` blocker. Fold a gated case in and note
   the result in `npm-package-compat`.

## 6. Testing

Deterministic diff tests vs Node (`test/diff/arguments*.js`), since every
behavior above is observable and comparable. Negative/edge coverage is
first-class: unmapped semantics (writing `arguments[0]` does *not* change
the param), `arguments` shadowed by a local, arrow-with-no-enclosing-
function still `not defined`, generator/async `arguments`, and
`fn.apply` arg forwarding. GC-stress the new allocation path.

## 7. Effort / risk

Moderate, and lower-risk than it looks because it rides the proven `this`
lane in the compiler. The real risk concentrates in three spots: the two
duplicated frame-setup sites drifting (mitigate by factoring a shared
helper), the generator/async carry (own test), and GC-rooting the object
across `normalize_args`. The object shape is easy to get subtly wrong
against Node (`length` enumerability, `Object.prototype` proto) — the diff
tests pin exactly those. No parser changes; no new global surface.

## 8. Decisions to confirm

- **Array-like object** (recommended) vs Array-backed (less code, but
  leaks Array methods and flips `Array.isArray`).
- **Unmapped** semantics (recommended; strict-mode behavior).
- **Lazy** build gated on compile-time use (recommended; zero cost when
  unused) vs always-build (simpler, per-call cost on every function).

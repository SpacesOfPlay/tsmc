# Property access

Where the interpreter's remaining time goes, what has been tried, and the
one change that would move it by more than a few percent.

Not a decision yet. Written after five rounds of measured optimisation had
taken the cheap wins and left property access as the largest cost, so the
next person starts from numbers rather than from scratch.

## What it costs today

`minc profile` on the two benchmarks that read and write the most properties,
2026-09-13, after the rounds recorded in `bench/BASELINE.md`:

| | `proto_chain` (reads down a 4-deep chain) | `classes` (instantiate, dispatch, getters) |
|---|---|---|
| the interpreter loop | 66% | 57% |
| the property machinery | 12% (`props_get` 6.4, `prop_get` 5.8) | 16% (`props_entry` 4.5, `prop_get` 3.3, `set_prop_atom` 3.1, `props_get` 3.1, `props_append` 0.8) |
| the value predicates | 10% | 9.5% |
| allocation and GC | — | 5% |
| the call path | — | 4% |

Against node these two are the worst of the fifteen benchmarks, >52x and 50x,
where the runtime-bound ones sit at 2-5x. The predicate share is the compiler's
(see `doc/inliner_improvements.md` in the minc tree); everything else here is
ours.

## Why a read costs what it does

An object is a `JsObject` with its own `PropList`: an array of
`{key, value, flags}` scanned linearly, with an `IntMap` index built once a
table passes eight entries. A read walks the prototype chain and looks in each
table until it hits.

That is fine per level and the levels are the problem. `d.av` where `av` lives
three levels up does four table lookups. Worse, a *write* of a fresh property
walks the whole chain before it may append, because a setter or a read-only
data property anywhere above must intercept -- and the chain ends at
`Object.prototype`, whose table is indexed and hashed. Every `this.x = x` in a
constructor pays that walk.

None of it is redundant work in the sense that a cache could skip it. It is
redundant across *iterations*: the same call site reads the same property of
the same shape of object thousands of times, and the interpreter re-derives the
answer every time.

## What has been tried

Landed, and measured in `bench/BASELINE.md`:

- The read walk became one function instead of four nested calls per level,
  with the getter called inline (`prop_get`): `proto_chain` -11%.
- A typed array's layout moved from three property lookups per element into
  fields on the view: `bytes` -10%.
- `value_is_primitive` reads the cell kind once instead of asking three
  predicates: ~2% on the object-heavy benchmarks.

Tried and reverted, both with numbers, so they are not re-tried:

- **A 64-bit key fingerprint per table**, so a level that lacks a name is
  rejected with a bit test. Measured **1% slower** across seven benchmarks. The
  objects on a chain hold one or two properties each, so the scan it replaces
  was already shorter than the load and mask it adds, and the eight bytes it
  costs every object are paid by everything else. The long tables it would have
  helped (`Object.prototype`) are the ones that already have an index.
- **A "this table holds an odd descriptor" bit**, to let a fresh-property write
  skip levels that cannot intercept it. `Object.prototype` carries the
  `__proto__` accessor, so the bit is set on the one level every chain ends at,
  and the fast path never applies. Making it per-name is the fingerprint above.

The pattern in both: every scheme that avoids re-deriving the answer needs
per-object state, and per-object state costs about 1% globally before it buys
anything.

## The change that would matter

Hidden classes and per-site inline caches, which is what the engines this is
measured against do.

**Shapes.** An object's identity becomes a pointer to a shared *shape*
describing its keys, their flags and their slot numbers; the object holds only
a flat array of values. Adding a property transitions to a new shape, and
shapes are interned so two objects built the same way share one. Two things
follow: an object with n properties costs one pointer plus n values rather than
a table of triples, and "does this object have this key, and where" is answered
by comparing one pointer against what a call site last saw.

**Inline caches.** Each `OP_GETPROP` / `OP_SETPROP` site gets a small cache in
the template, keyed by shape: on a hit, the read is a slot load. A miss falls
back to the walk that exists today and records the shape it found. Monomorphic
sites -- which is most of them -- stop walking the chain entirely, and a fresh
property write stops proving the absence of a setter on every construction,
because the shape it transitions to already encodes it.

This is not a tuning pass. It replaces the object model, touches every path
that reads or writes a property, and interacts with:

- **Proxies, arrays, typed arrays, the global object and module namespaces**,
  which answer for names their own way. They keep the slow path; the cache has
  to refuse to arm for them, exactly as `prop_get` bails for them today.
- **`delete`** and `Object.defineProperty`, which move an object off its shape.
  A dictionary mode for objects that churn is the usual answer.
- **The GC**, which must trace the value array and keep shapes alive.
- **The frame-size rule** (`doc/DESIGN_bytecode.md`): new opcode cases declare
  no locals and delegate, or the deep native re-entry test crashes.
- **`--gc-stress`**, which is what would catch a missed root in the value
  array.

A staged version is possible and worth preferring: shapes first, with the
existing lookup rewritten on top of them and no caches (the win is the flat
value array and the interned key set), then caches at the two opcodes, then
the write path's absence proof.

## What not to expect

The interpreter loop is 57-66% of these benchmarks and shapes do not touch it.
Caching a read that costs 12-16% cannot pay more than that, plus whatever the
write path's chain walk is worth in `classes`. A fair guess from the profiles
is a third off the two worst benchmarks, taking them from ~50x to ~35x against
node -- worth doing, and not the order of magnitude that a compiler would be.
The band that matters for real code is the 2-5x one, and property access is
already not what dominates there.

# Allocation

What making an object, an array or an iteration step costs, what was taken out
of those paths, and how small a difference this machine can actually measure.

Written after the round of 2026-09-13. The profiles that started it are in
`doc/DESIGN_property_access.md`: on the data-plumbing workload the C allocator
was 24% of the time and the collector 16%, against 5-6% for property lookup. So
the question was not how fast a lookup is but how much is allocated.

## What a fresh object cost

`{ id, name, kind, price, ok, meta }` in a loop, 400k times, profiled at
`props_get` 10.5%, `def_prop` 7.7%, `props_append` 5.6%, `def_prop_atom` 4.2%,
`props_set` 2.8%, `js_set_prop` 2.1%. For each of the six keys:

- `props_entry` scanned the table to check the key was not one that cannot be
  redefined,
- `props_get` scanned it again to decide whether the object was being extended,
- the store scanned it a third time before appending,
- and the storage was allocated at four entries and reallocated at eight.

Three of those scans answer a question the compiler has already settled. A plain
key of a literal cannot be there yet when no spread and no computed key has run
before it and no earlier key of the same literal interns to the same atom. That
is `OP_DEFPROP_NEW`, which appends and nothing else. The count of keys rides
along on `OP_NEWOBJ`, so the table is sized once. And since `OP_DEFPROP` leaves
the object on the stack, the literal no longer duplicates it and pops the copy
per property.

400k six-key literals: **200ms -> 115ms**, and the `objlit` benchmark this
round added **589ms -> 415ms**.

The same pass found that defining a property over an existing one kept the old
attribute bits, so `{ get a() {...}, a: 2 }` left `a` non-writable. A define
replaces the descriptor; that is a separate commit with its own tests.

## What a fresh array cost

Element storage doubles from eight, so an n-element result is copied log n times
on the way up. Where the size is known before the first write -- an array
literal, a spread of an array, `slice`, `concat`, `map`, an object's key list --
it is allocated once. `filter` takes the source length as an upper bound, capped
at 1024 so that keeping a handful out of a million does not hold a slot per
dropped element.

Copying 50k-element arrays (`slice`, `concat`, spread, `Array.from`): **127ms ->
120ms**, which is a 5% win on a workload that varies by 5% between passes -- the
mechanism is certain, the number is at the floor. Behind `filter` and `map` the
callback calls are so much larger that nothing shows at all (195 -> 192ms).

## What an iteration step cost

`for-of` over an array already stepped without building a result object. Over a
`Map` or a `Set` it still called `next()`, which allocated a `{value, done}`
object and interned both key strings, per entry. The same hook now recognises
those iterators; `entries` builds the pair it yields and nothing around it.

2000-entry collections iterated 300 times over: **927ms -> 460ms**; the
`collections` benchmark 71 -> 62ms.

Anything that can observe the difference keeps the old path: a `next()` that has
been replaced, a `next()` called from JavaScript (which gets a real result
object), and `yield*`, which sends a value in.

## How small a difference this machine can measure

Every number above is the least of eight runs, all binaries timed inside the same
minute with their order reversed on every other run, and each built from its
commit with the same compiler. All three parts of that are load-bearing:

- **What built each binary.** `bench` and `diff` build tsmc themselves, so a
  comparison set assembled over a day can quietly contain binaries that were not
  produced the same way, and a toolchain of another version is a different
  measurement. An early reading of this round blamed 7% on code layout when the
  two binaries had simply not been built alike. The build prints what produced
  it; build every binary in a set from its own commit, the same way.
- **The pass.** Two `minc bench` passes minutes apart differ by up to 9% on
  workloads nothing touched. A bench pass is a snapshot against node, not an A/B.
- **The position.** Inside one round the binary timed second read up to 6% faster
  than the same binary timed first.

Comments and function order are *not* a factor, which was worth checking rather
than assuming: the build is deterministic (same source, byte-identical binary), a
one-character comment edit leaves `.text` byte-identical, and moving a private
function changes 261 of its 1.9M bytes.

The floor that remains is the repeatability of the whole procedure: about 2% on
the steady workloads, 5% on the short allocation-heavy ones. Below that, the
mechanism has to carry the claim (this many allocations became one), or there is
no claim.

## What is left

- **`JSON.parse`** builds objects a key at a time and cannot know the count in
  advance; it is the one hot object-construction path still growing its table
  from four. Close to node already, so not urgent.
- **A property table takes a hash index at sixteen keys**, which is an
  allocation and a second structure to maintain. Dictionary-shaped objects want
  it; a literal with twenty keys does not.
- **A generator's `next()`** still allocates a result object per step, and so
  does any iterator the built-ins did not install.
- **Strings** are copied once more than they need to be when a builder's buffer
  becomes a string cell. Separate topic, see `doc/DESIGN_string.md`.
- **Shapes** would make all of this moot for objects that share a layout, and
  remain the one change with a large ceiling. `doc/DESIGN_property_access.md`
  sketches it.

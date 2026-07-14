# M1 — infrastructure

Foundation modules everything else builds on. No parsing, no VM yet.
Design context: `DESIGN_value.md`, `DESIGN_gc.md`.

## Deliverables

| Module | Contents |
|--------|----------|
| `src/value.mc` | NaN-boxed `Value`: constructors, accessors, predicates |
| `src/gc.mc` | `GcHeap`: cell allocator, mark-sweep, root stack, stress mode; `GcString`, `GcPair` cell kinds |
| `src/map.mc` | `StrMap<V>` and `IntMap<V>`: open-addressing hash maps |
| `src/atom.mc` | `AtomTable`: interned strings, stable u32 ids |
| `src/diag.mc` | `DiagList`: severity + span + message, line/col derivation |

Tests: one `test/unit/test_<module>.mc` per module, plus shared
assertions in `test/helpers/check.mc`.

## Key choices

- **Hash maps**: linear probing, power-of-two capacity, tombstones,
  grow at 75% fill. Two key flavors (`str`, `u32`) with duplicated
  probe logic — minc generics parameterize the value type only; a
  generic key would need hash/eq abstraction that isn't worth it for
  two instances. Keys are borrowed; callers own key lifetime.
- **Generics constraint** (compiler 0.9.8): a field or local of nested
  generic type (`Slot<V>*`) does not unify inside generic functions.
  Generic struct fields must use the type parameter directly (`V*`),
  hence the parallel-array map layout. Locals infer with `var`;
  generic-to-generic calls pass `<V>` explicitly.
- **Atoms**: `StrMap<u32>` from name to id, `Vec<str>` from id to name.
  The table owns copied name bytes (plain allocations, freed on table
  teardown). Atoms are never collected — acceptable until dynamic
  property keys profile as a leak (revisit with weak atom refs then).
- **Pair cell kind** (`GC_PAIR`, two Values) exists so GC tracing has
  a linkable cell type before real object kinds land in M5.
- **Diag messages** are copied on add and freed with the list, so
  callers can pass `format(...)` output and free their copy
  immediately.
- The stdlib `Arena` is fixed-capacity, so string ownership here uses
  per-item allocations instead. A growable chunk arena can come with
  the AST milestone that actually needs bulk-free.

## Exit criteria

- `./build.ps1 test` green: all five unit tests pass, GC tests pass
  with stress mode on.
- No global mutable state in any module; everything reachable from
  the structs.

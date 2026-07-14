# M4 — lowering

AST-to-AST passes that turn the parsed TS into plain ES the bytecode
compiler can consume without any TS knowledge. Deliverables:
`src/lower.mc`, `test/unit/test_lower.mc`.

## Stripping

Dropped outright: `interface`, `type` aliases, anything flagged
`declare`, function overload signatures, abstract members, type-only
imports/exports (whole statements and individual specifiers; an import
whose bindings all filtered away is dropped, a bare side-effect import
stays). `as` / `satisfies` / non-null `!` unwrap to their operand.

## Enums

Standard TS emission shape, built as plain AST:

```
var E;
(function (E) {
    E[E["A"] = 0] = "A";       // numeric members get reverse mapping
    E["S"] = "text";           // string members don't
})(E || (E = {}));
```

Member values const-fold (literals, references to earlier members of
the same enum, `+ - * / << >> >>> & | ^ ~` with JS ToInt32 semantics);
auto-increment continues from folded values. A member after a
non-constant initializer must be initialized — diagnostic otherwise.
`const enum` lowers as a regular enum (Bun/isolatedModules behavior);
cross-module inlining is out of scope.

## Namespaces

IIFE emission with proper scoping:

```
var N;
(function (N) {
    const x = 1;
    N.x = x;                   // exported members assigned through
})(N || (N = {}));
```

Nested and dotted namespaces chain through the parent object
(`(function (B) {…})(B = A.B || (A.B = {}))`); the parser marks
dotted inner namespaces exported. Exported `let`/`var` are emitted the
same way with a warning — inner reassignment does not propagate to the
namespace object (TS rewrites references; revisit if real code needs
it).

## Parameter properties

`constructor(private x: T)` keeps `x` as a plain parameter and injects
`this.x = x;` at the top of the constructor body — after the leading
`super(…)` call when the class has a heritage clause.

## Scope analysis moved to M5

Hoisting, TDZ, and capture analysis produce data whose shape is
dictated by bytecode slot allocation. Building them here would mean
guessing that shape; they land in M5 fused with the compiler.

## Tests

Golden post-lowering dumps: stripping, unwrapping, both enum forms,
folding chains, namespace export shapes, dotted nesting, parameter
properties with and without `super()`, module-level `export enum`.
Error case: enum auto-increment after a computed member.

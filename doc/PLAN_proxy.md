# PLAN — `Proxy` and `Reflect`

Implements the `Proxy` exotic object and its companion `Reflect`. This is
the largest of the open npm-compatibility gaps: it unblocks the
reactivity/immutability family (`immer`, `mobx`, Vue 3 reactivity) and any
library that wraps objects to intercept property access. Unlike the
`arguments` / named-function-expression fixes, this is not a one-lane
change — a `Proxy` must intercept *every* fundamental object operation, so
the work is spread across the object model's operation sites.

*Revised after a code-grounded scope review; the revision surfaced three
issues the first draft missed (the prefix-proto default, array targets,
and proxy-in-prototype-chain), reordered the increments, and added an
explicit audit list of direct-`props` readers.*

## 1. What a Proxy is

`new Proxy(target, handler)` returns an object whose fundamental internal
methods are forwarded to `handler` traps; a missing trap falls back to the
same operation on `target` (which is exactly what the matching `Reflect`
method does). The traps, and where each is triggered in tsmc:

| trap | triggered by |
|---|---|
| `get` | `obj.k`, `obj[k]` |
| `set` | `obj.k = v`, `obj[k] = v` |
| `has` | `k in obj` |
| `deleteProperty` | `delete obj.k` |
| `ownKeys` | `for-in`, `Object.keys`, spread `{...obj}`, `JSON.stringify` |
| `getOwnPropertyDescriptor` | `Object.getOwnPropertyDescriptor`, and internally by `ownKeys` consumers |
| `defineProperty` | `Object.defineProperty` |
| `getPrototypeOf` | `Object.getPrototypeOf`, `instanceof`, proto walks |
| `setPrototypeOf` | `Object.setPrototypeOf` |
| `isExtensible` / `preventExtensions` | `Object.isExtensible` / `Object.preventExtensions` |
| `apply` | calling a proxy whose target is callable |
| `construct` | `new` on a proxy whose target is a constructor |

`Reflect` exposes the default of each as a static method
(`Reflect.get(t, k, r)`, `Reflect.ownKeys(t)`, …); libraries call these
inside their traps to "do the normal thing, then react."

## 2. Representation

A Proxy must satisfy `value_is_object(p) === true` (it is an object for
`typeof`, prototype checks, and the pervasive `value_as_object` casts), yet
carry a `target` and `handler` and route operations specially.

**Recommended:** a `JsProxy` whose leading fields are byte-identical to
`JsObject`, allocated with kind `GC_OBJECT` and a new `OBJF_PROXY` flag,
followed by two extra fields:

```
struct JsProxy {
    // --- identical prefix to JsObject ---
    GcCell head; i32 obj_flags; JsObject* proto;
    PropList props; Value* elems; i32 elen; i32 ecap;
    // --- proxy state ---
    Value target;
    Value handler;
}
```

So `value_is_object` and `value_as_object` keep working unchanged, and each
operation site does one cheap `(o.obj_flags & OBJF_PROXY)` test — the same
shape as the existing `OBJF_ARRAY` / `OBJF_TYPEDARRAY` checks. GC tracing
gains an `OBJF_PROXY` arm that marks `target` and `handler`.

**Prefix `proto` must be a snapshot of the target's proto** (set at
construction). Direct `o.proto` reads happen all over — `instanceof`
walks, `js_get_prop`'s internal chain walk starting from a *child* object,
`Object.getPrototypeOf` — and none of them can call traps. With the
snapshot, the untrapped default ("a proxy behaves like its target")
holds for all of them; the cost is that a later change to the *target's*
proto is not reflected through the proxy (acceptable; noted in §7). The
proxy's own `props`/`elems` stay empty and unused. **`OBJF_ARRAY` is never
set on a proxy** — see §4.

Rejected alternatives: a distinct `GC_PROXY` kind (forces a large
`value_is_object` / `value_as_object` audit); two new fields on every
`JsObject` (bloats every object for a rare feature).

## 3. Interception points (grounded in the code)

Most fundamental ops funnel through a few central helpers:

- **get** — `get_prop_atom` (vm.mc), one check at the top of its
  `value_is_object` branch. Covers `OP_GETPROP` and the general
  `OP_GETINDEX` path.
- **set** — `set_prop_atom`. Covers `OP_SETPROP` / `OP_SETINDEX`.
- **has** — `OP_IN`.
- **deleteProperty** — `OP_DELINDEX`.
- **ownKeys** — `vm_own_keys` is a genuine single choke point: for-in,
  object spread (`OP_KEYS`), and `JSON.stringify` all route through it and
  then read values via `vm_get_prop_value` (which traps `get`). Plus the
  `Object.keys`/`getOwnPropertyNames` natives.
- **descriptor traps** — the `Object.*` natives.
- **apply / construct** — `OP_CALL` / `OP_NEW` and `vm_call_stack`.
  `value_is_callable` (object.mc, kind-based) must pierce: a proxy is
  callable iff its target is; same for `typeof` reporting `'function'`.

**Known limitation (v1): a proxy used as a *prototype* cannot trap.**
`js_get_prop` / `js_set_prop` / `js_has_prop` walk the proto chain inside
object.mc with no VM access, so a walk that *passes through* a proxy reads
its (empty) props instead of trapping. The proxy-at-the-receiver case —
which is what the reactivity libraries do — works fully; proxies-as-
prototypes are rare "magic object" patterns. Fixing it needs a sentinel
("walk stopped at a proxy") return from the object.mc walkers so the VM
can resume with a trap call — deferred, documented.

**Direct-`props` readers (the silent-bypass audit).** These natives read
`src.props` / `elems` directly and would silently see a proxy as *empty*;
each needs a proxy branch (usually: route through `vm_own_keys` +
`vm_get_prop_value`) or an explicit unsupported-error:
`Object.assign` (both its array and props branches), `structuredClone`,
`Object.entries`/`values`, `Object.freeze`/`isFrozen`/`seal`
(`object_lock_props`), `getOwnPropertyDescriptors`, `util.inspect`/
`console.log` formatting. This list is the I2 checklist; the acceptance
test is that each either traps correctly or throws loudly — never
silently returns empty.

## 4. Array targets — required for the flagship payoff

immer/Vue proxy *arrays* as their bread-and-butter case, and arrays are
where the naive design breaks:

- `Array.isArray(proxyOfArray)` must be `true` (the spec pierces proxies).
  But setting `OBJF_ARRAY` on the proxy would send the VM's array fast
  paths (`OP_GETINDEX`/`OP_SETINDEX`, `vm_own_keys`'s array branch,
  `Object.assign`'s array branch) straight to the proxy's *own empty
  elems* — silently bypassing every trap. So: `value_is_array` pierces to
  the target (it stays a pure object.mc predicate — reading the target's
  flag needs no VM), while the fast paths switch to a new flag-only
  `value_is_real_array` so proxies fall through to the generic (trapping)
  path.
- `draft.push(x)` — an Array.prototype native invoked with a proxy
  `this` — reaches `this_array`, which requires a real array and fails
  today. Supporting it means the Array natives must work generically
  against array-like receivers (length + indexed get/set through
  `vm_get_prop_value`/`set_prop_atom`, which trap). **This is the same
  "array-like receiver" gap already on the compat list** (blocks
  `markdown-it` and `Array.prototype.slice.call(arguments)`), which makes
  it a natural *prerequisite* increment: land it first, independently —
  it pays for itself before Proxy even starts.

## 5. `Reflect`

A global object with the 13 static methods, each the default of the
matching trap, mostly thin wrappers over existing helpers
(`Reflect.get`→`get_prop_atom`, `Reflect.ownKeys`→`vm_own_keys`,
`Reflect.apply`/`construct`→the call machinery). In scope from I1: trap
bodies almost always call it, and immer references `Reflect` at module
load.

## 6. Scope decisions

- **Skip invariant enforcement in v1.** The spec requires traps to be
  consistent with non-configurable/non-extensible target properties; the
  checks are intricate and the reactive libraries don't depend on them.
  Consequence: a program relying on a proxy *throwing* for an invariant
  violation won't see the throw. Documented, revisit on demand.
- **Proxies as prototypes: out of scope v1** (see §3). Receiver-position
  proxies — the actual library pattern — are fully in scope.
- **Object-target traps land before array-target support**; immer works
  for plain-object drafts one increment before array drafts.

## 7. Increments

0. **I0 — array-like receivers for Array natives (independent
   prerequisite). (done)** A new `this_arraylike` materializes a real array
   from any array-like receiver (numeric `length` + indexed reads via
   `vm_get_prop_value`, so it also traps proxy element reads later); the 16
   non-mutating Array natives use it, while the 9 mutating natives keep the
   strict `this_array` (a non-array receiver is refused loudly, never
   silently mis-mutated). `concat` keeps strict too (IsConcatSpreadable: a
   non-array `this` is one element, not spread). Real arrays take the
   unchanged fast path. `Array.prototype.slice/map/reduce/…​.call(arguments)`
   and plain array-likes now work (`test/diff/arraylike_receiver.js` matches
   Node); this closes the `slice.call(arguments)` follow-up from the
   `arguments` milestone. `markdown-it` advances past its slice.call blocker
   but then hits a separate `linkify-it` issue, so it remains unlisted.
   Mutating-on-array-like (`push.call(arrayLike)`) write-back is still out of
   scope.
1. **I1 — core + Reflect basics. (done)** `JsProxy` (JsObject-prefix +
   `OBJF_PROXY`, GC-traced target/handler), the `Proxy` constructor with the
   proto snapshot, and the `get`/`set`/`has`/`deleteProperty` traps wired at
   their sites — `get_prop_atom`, `set_prop_atom`, `OP_IN`, and **both**
   `OP_DELPROP` (dot) and `OP_DELINDEX` (computed) delete opcodes. Each trap
   falls back to the target when absent, throws if a present trap is not
   callable, and propagates exceptions. `Reflect.get`/`set`/`has`/
   `deleteProperty`/`getPrototypeOf`/`ownKeys` (a public `vm_set_prop_value`
   was added for `Reflect.set`). `typeof` an object-target proxy is
   `'object'`; callability piercing is deferred to I3. `test/diff/proxy.js`
   matches Node (traps + Reflect defaults, validating proxy, nested/recursive
   proxies, symbol-keyed get, dot+computed delete, non-object target/handler
   TypeErrors). Two bugs the review's "silent-bypass" concern predicted were
   caught and fixed: dot-form `delete` used a separate opcode (`OP_DELPROP`),
   and a pre-existing gap where `arr["1"]` (string-numeric key) skipped the
   element part — now fixed in `get_prop_atom`/`set_prop_atom` for all paths.
   A missing GC root on the `Reflect` object under `--gc-stress` was fixed.
2. **I2 — enumeration + descriptors + the bypass audit. (done)** The
   `ownKeys` trap is wired at `vm_own_keys` (the choke point for for-in,
   `Object.keys`, spread, `JSON.stringify`) plus `Reflect.ownKeys`; the
   `getOwnPropertyDescriptor` and `defineProperty` traps are wired at the
   `Object.*` natives and `Reflect`. The direct-`props` bypass audit was
   worked through — a proxy branch (route through the ownKeys + get traps)
   was added to every consumer that read `.props` directly: `Object.assign`,
   `Object.values`/`entries`, **`OP_OBJ_SPREAD`** (object spread), and
   **`JSON.stringify`** (the last two were not on the original audit list —
   found by testing, exactly the silent-bypass the plan warned about).
   `Proxy.revocable` (planned for I3) was pulled forward because immer needs
   it, and `Object.prototype.propertyIsEnumerable` (a general pre-existing
   gap) was added. **Payoff reached: immer works** — `produce` with nested
   object mutation, structural sharing, and JSON output all match Node.
   `test/diff/proxy.js` covers the enumeration/descriptor/revocable surface.
3. **I3 — callable proxies + Array.isArray. (done, reduced scope)** The
   `apply` and `construct` traps are wired into the `OP_CALL`/`OP_NEW`
   dispatch (a callable-target proxy routes through them); `value_is_callable`
   and `typeof` pierce to the target so a function-target proxy is callable
   and reports `'function'`. `Array.isArray` pierces proxies (transitively).
   `Reflect.apply`/`construct` added (the traps default through them).
   `Proxy.revocable` already landed in I2. `test/diff/proxy_call.js` matches
   Node (apply/construct + Reflect defaults, `this` threading, `instanceof`,
   Array.isArray piercing over proxy-of-array incl. reads/iteration, callable
   vs non-callable, direct Reflect.apply/construct).
   **Deliberately deferred (own follow-up):** array-target *write* support —
   mutating Array methods (`push`/`splice`/…) on a proxy receiver need the
   array-like write-back rework, and **immer array drafts** fail deeper in
   immer's own array-target machinery (the `target=[state]` + arrayTraps
   pattern), so they remain unsupported; immer *object* drafts (the I2
   payoff) work. Also still deferred: the `getPrototypeOf`/`setPrototypeOf`/
   `isExtensible`/`preventExtensions` traps (low-value; the snapshot proto
   covers the common `Object.getPrototypeOf` case) and invariant enforcement.
4. **I4 — payoff + docs.** Run immer (objects + arrays) and a mobx/Vue
   snippet; fold deterministic cases into the diff suite; update
   `doc/npm-compatibility.md` + the `npm-package-compat` memory.

## 8. Testing

Diff tests vs Node (`test/diff/proxy*.js`, `reflect*.js`) — every trap is
observable. Cover: each trap firing, trap-absent defaulting, `Reflect`
round-trips, nested/recursive proxies (a `get` returning a proxy of the
child — the reactivity pattern), `receiver` threading, arrays behind
proxies (index read/write, `push`, `length`, `Array.isArray`, `for-of`),
spread/`JSON.stringify`/`Object.assign`/`for-in` over proxies (the bypass
audit, asserted against Node), and error propagation when a trap throws.
GC-stress the trap paths (each trap allocates and re-enters the
interpreter).

## 9. Effort / risk

**Highest of the open compat items — and higher than the first draft of
this plan suggested.** The scope review added: the proto-snapshot
requirement, the array-target/fast-path split, the Array-natives
prerequisite (I0), and a concrete direct-`props` bypass audit. The failure
mode to engineer against is *silent* bypass (an op site that reads the
proxy's empty storage instead of trapping) — hence the audit list and the
assert-against-Node tests for every consumer. Trap calls are re-entrant JS
(root + propagate `has_pending` at every site). Perf risk stays low: one
masked flag test per op site. Realistic shape: I0 as its own small
milestone, then three build-green Proxy increments — this is multi-session
work.

## 10. Out of scope / follow-ups

Invariant/consistency enforcement, proxies as prototypes (sentinel-based
walker fix), live (non-snapshot) proto forwarding, and full spec
conformance of `receiver` semantics in accessor inheritance.

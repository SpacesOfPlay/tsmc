// Well-known symbols and the protocols they hook: Symbol.iterator,
// asyncIterator, toPrimitive, toStringTag and hasInstance, plus how
// symbol-keyed properties behave under enumeration and copying.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// Symbol basics.
T('typeof', () => typeof Symbol());
T('description', () => Symbol('d').description);
T('description-none', () => Symbol().description);
T('toString', () => Symbol('s').toString());
T('for-registry', () => Symbol.for('k') === Symbol.for('k'));
T('for-vs-plain', () => Symbol.for('k') === Symbol('k'));
T('keyFor', () => Symbol.keyFor(Symbol.for('kk')));
T('keyFor-unregistered', () => Symbol.keyFor(Symbol('u')));
T('unique', () => Symbol('a') === Symbol('a'));
T('implicit-string-throws', () => '' + Symbol('x'));
T('template-throws', () => `${Symbol('x')}`);
T('String()-ok', () => String(Symbol('x')));
T('wellknown-shared', () => Symbol.iterator === Symbol.iterator);
T('wellknown-desc', () => Symbol.iterator.toString());
T('wellknown-desc-prop', () => Symbol.asyncIterator.description);

// Symbol-keyed properties. They stay out of Object.keys / for-in / JSON, but
// are copied by assign and spread and listed by Reflect.ownKeys.
T('key-set-get', () => { const s = Symbol('k'); const o = { [s]: 1 }; return o[s]; });
T('key-not-in-keys', () => { const s = Symbol('k'); const o = { [s]: 1, a: 2 }; return Object.keys(o); });
T('key-not-in-for-in', () => { const s = Symbol('k'); const o = { [s]: 1, a: 2 }; const r = []; for (const k in o) r.push(k); return r; });
T('key-in-getOwnPropertySymbols', () => { const s = Symbol('k'); const o = { [s]: 1 }; return Object.getOwnPropertySymbols(o).length; });
T('key-not-in-getOwnPropertyNames', () => { const s = Symbol('k'); return Object.getOwnPropertyNames({ [s]: 1, a: 2 }); });
T('key-not-in-JSON', () => { const s = Symbol('k'); return JSON.stringify({ [s]: 1, a: 2 }); });
T('key-in-operator', () => { const s = Symbol('k'); const o = { [s]: 1 }; return s in o; });
T('key-ownKeys-count', () => { const s = Symbol('k'); const o = { a: 1, [s]: 2 }; return Reflect.ownKeys(o).length; });
T('key-ownKeys-strings-first', () => { const s = Symbol('k'); const o = { [s]: 1, a: 2 }; const ks = Reflect.ownKeys(o); return [typeof ks[0], typeof ks[1]]; });
T('key-assign-copies', () => { const s = Symbol('k'); const o = Object.assign({}, { [s]: 5 }); return o[s]; });
T('key-spread-copies', () => { const s = Symbol('k'); const o = { ...{ [s]: 6 } }; return o[s]; });
T('key-rest-copies', () => { const s = Symbol('k'); const { a, ...r } = { a: 1, [s]: 7 }; return r[s]; });
T('key-assign-keeps-strings', () => { const s = Symbol('k'); return JSON.stringify(Object.assign({}, { a: 1, [s]: 2 })); });
T('key-delete', () => { const s = Symbol('k'); const o = { [s]: 1 }; delete o[s]; return s in o; });
T('key-descriptor', () => { const s = Symbol('k'); return JSON.stringify(Object.getOwnPropertyDescriptor({ [s]: 1 }, s)); });
T('key-JSON-value-omitted', () => JSON.stringify({ a: Symbol('v') }));
T('key-JSON-array-null', () => JSON.stringify([Symbol('v')]));
T('key-computed-class', () => { const s = Symbol('m'); class C { [s]() { return 'hit'; } } return new C()[s](); });

// Symbol.iterator.
T('iter-custom-object', () => { const o = { [Symbol.iterator]() { let i = 0; return { next: () => i < 3 ? { value: i++, done: false } : { value: undefined, done: true } }; } }; return [...o]; });
T('iter-custom-for-of', () => { const o = { [Symbol.iterator]: function* () { yield 'a'; yield 'b'; } }; const r = []; for (const x of o) r.push(x); return r; });
T('iter-custom-destructure', () => { const o = { [Symbol.iterator]: function* () { yield 1; yield 2; } }; const [a, b] = o; return [a, b]; });
T('iter-Array-from', () => { const o = { [Symbol.iterator]: function* () { yield 7; } }; return Array.from(o); });
T('iter-class', () => { class C { *[Symbol.iterator]() { yield 1; yield 2; } } return [...new C()]; });
T('iter-missing-throws', () => [...{}]);
T('iter-on-string', () => typeof ''[Symbol.iterator]);
T('iter-on-array', () => typeof [][Symbol.iterator]);
T('iter-on-map', () => typeof new Map()[Symbol.iterator]);
T('iter-array-values-same', () => Array.prototype[Symbol.iterator] === Array.prototype.values);
T('iter-values-name', () => Array.prototype.values.name);
T('iter-return-called-on-break', () => { let closed = false; const o = { [Symbol.iterator]: () => ({ next: () => ({ value: 1, done: false }), return: () => { closed = true; return { done: true }; } }) }; for (const x of o) break; return closed; });

// Symbol.toPrimitive.
T('toPrimitive-number', () => { const o = { [Symbol.toPrimitive]: (h) => h === 'number' ? 42 : 'str' }; return +o; });
T('toPrimitive-string', () => { const o = { [Symbol.toPrimitive]: (h) => h === 'number' ? 42 : 'str' }; return `${o}`; });
T('toPrimitive-default', () => { const o = { [Symbol.toPrimitive]: (h) => h }; return o + ''; });
T('toPrimitive-hint-order', () => { const seen = []; const o = { [Symbol.toPrimitive]: (h) => { seen.push(h); return 1; } }; +o; `${o}`; o + 1; o == 1; return seen; });
T('toPrimitive-overrides-valueOf', () => { const o = { [Symbol.toPrimitive]: () => 9, valueOf: () => 1, toString: () => '2' }; return +o; });
T('toPrimitive-date-default', () => typeof (new Date()[Symbol.toPrimitive]));

// Symbol.toStringTag.
T('tag-custom', () => { const o = { [Symbol.toStringTag]: 'Custom' }; return Object.prototype.toString.call(o); });
T('tag-getter', () => { class C { get [Symbol.toStringTag]() { return 'C'; } } return Object.prototype.toString.call(new C()); });
T('tag-inherited', () => { const proto = { [Symbol.toStringTag]: 'P' }; return Object.prototype.toString.call(Object.create(proto)); });
T('tag-non-string-ignored', () => Object.prototype.toString.call({ [Symbol.toStringTag]: 5 }));
T('tag-map', () => Object.prototype.toString.call(new Map()));
T('tag-set', () => Object.prototype.toString.call(new Set()));
T('tag-weakmap', () => Object.prototype.toString.call(new WeakMap()));
T('tag-weakset', () => Object.prototype.toString.call(new WeakSet()));
T('tag-promise', () => Object.prototype.toString.call(Promise.resolve()));
T('tag-json', () => Object.prototype.toString.call(JSON));
T('tag-math', () => Object.prototype.toString.call(Math));
T('tag-generator', () => { function* g() {} return Object.prototype.toString.call(g()); });
T('tag-array', () => Object.prototype.toString.call([]));
T('tag-null', () => Object.prototype.toString.call(null));
T('tag-undefined', () => Object.prototype.toString.call(undefined));
T('tag-number', () => Object.prototype.toString.call(5));
T('tag-string', () => Object.prototype.toString.call('s'));
T('tag-function', () => Object.prototype.toString.call(function () {}));
T('tag-date', () => Object.prototype.toString.call(new Date()));
T('tag-regexp', () => Object.prototype.toString.call(/x/));
T('tag-error', () => Object.prototype.toString.call(new Error('e')));
T('tag-map-value', () => Map.prototype[Symbol.toStringTag]);
T('tag-symbol-proto', () => Symbol.prototype[Symbol.toStringTag]);
T('tag-not-enumerable', () => Object.keys(Math).length);
T('tag-overridable', () => { const m = new Map(); m[Symbol.toStringTag] = 'Mine'; return Object.prototype.toString.call(m); });

// Symbol.hasInstance.
T('hasInstance-object', () => { const o = { [Symbol.hasInstance]: (v) => v === 1 }; return [1 instanceof o, 2 instanceof o]; });
T('hasInstance-static', () => { class C { static [Symbol.hasInstance](v) { return typeof v === 'string'; } } return ['x' instanceof C, 5 instanceof C]; });
T('hasInstance-receives-value', () => { let got; const o = { [Symbol.hasInstance]: (v) => { got = v; return true; } }; 'probe' instanceof o; return got; });
T('hasInstance-truthy-coerced', () => { const o = { [Symbol.hasInstance]: () => 'yes' }; return 1 instanceof o; });
T('hasInstance-default-still-works', () => { class C {} return new C() instanceof C; });
T('hasInstance-default-subclass', () => { class A {} class B extends A {} return [new B() instanceof A, new A() instanceof B]; });
T('hasInstance-non-callable-rhs', () => 1 instanceof {});

// Symbol.asyncIterator.
T('asyncIterator-exists', () => typeof Symbol.asyncIterator);
T('asyncIterator-distinct', () => Symbol.asyncIterator === Symbol.iterator);

// `for await` prefers Symbol.asyncIterator, else falls back to Symbol.iterator.
async function main() {
  const out = [];
  const custom = {
    [Symbol.asyncIterator]() {
      let i = 0;
      return { next: () => Promise.resolve(i < 3 ? { value: i++, done: false } : { done: true }) };
    },
  };
  for await (const v of custom) out.push(v);
  rows.push('for-await-asyncIterator = ' + JSON.stringify(out));

  // With both present, the async one wins.
  const both = {
    [Symbol.asyncIterator]: function () { let i = 0; return { next: () => Promise.resolve(i++ < 1 ? { value: 'async', done: false } : { done: true }) }; },
    [Symbol.iterator]: function* () { yield 'sync'; },
  };
  const picked = [];
  for await (const v of both) picked.push(v);
  rows.push('for-await-prefers-async = ' + JSON.stringify(picked));

  // Sync-iterable fallback, with each yielded value awaited.
  const sync = { [Symbol.iterator]: function* () { yield Promise.resolve('a'); yield 'b'; } };
  const fell = [];
  for await (const v of sync) fell.push(v);
  rows.push('for-await-sync-fallback = ' + JSON.stringify(fell));

  console.log(rows.join('\n'));
}
main();

// Not asserted, all unimplemented:
//   - Symbol.species: Array subclass map/filter/slice return the base Array,
//     and Array[Symbol.species] / Promise[Symbol.species] are absent.
//   - Symbol.match / replace / search / split: String.prototype's methods do
//     not hand off to them, and RegExp.prototype does not define them, so
//     `IsRegExp` does not consult Symbol.match either.
//   - Symbol.isConcatSpreadable is ignored by Array.prototype.concat.
//   - Function.prototype[Symbol.hasInstance] is absent (instanceof still
//     implements the ordinary behaviour inline).
//   - An async generator object does not expose Symbol.asyncIterator; `for
//     await` reaches it through the sync-iterator fallback above.

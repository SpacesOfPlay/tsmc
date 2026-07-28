// Operator and expression semantics: optional chaining, template literals and
// tagged templates, spread, compound assignment, the arithmetic and bitwise
// edges, delete/typeof/void/in, and switch.
//
// A module, not a script, because `delete` on a non-configurable property is
// one of the checks: that is a silent false in sloppy mode and a TypeError in
// strict, and tsmc is strict everywhere. Under node the two spellings differ
// on exactly that line.

const out = [];

function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'bigint') return v + 'n';
  if (typeof v === 'symbol') return v.toString();
  if (typeof v === 'function') return 'fn:' + (v.name || '?');
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
  if (typeof v === 'number' && Object.is(v, -0)) return '-0';
  if (typeof v === 'object') {
    try { return JSON.stringify(v); } catch (e) { return String(v); }
  }
  return String(v);
}

function T(label, fn) {
  let v;
  try { v = fn(); } catch (e) {
    v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e));
  }
  out.push(label + ' = ' + show(v));
}

// --- optional chaining ------------------------------------------------------

const oc = { a: { b: { c: 42 } }, n: null, f: () => 'called', arr: [1, 2, 3] };

T('oc-deep', () => oc.a.b.c);
T('oc-missing-mid', () => oc.x?.y?.z);
T('oc-null-mid', () => oc.n?.anything);
T('oc-index', () => oc.arr?.[1]);
T('oc-index-missing', () => oc.missing?.[0]);
T('oc-call', () => oc.f?.());
T('oc-call-missing', () => oc.nope?.());
T('oc-method-this', () => {
  const o = { v: 9, m() { return this.v; } };
  return o.m?.();
});
// the whole chain short-circuits, not just the next link
T('oc-shortcircuit-whole', () => oc.n?.a.b.c.d.e);
T('oc-shortcircuit-call', () => oc.n?.a().b().c());
T('oc-shortcircuit-index', () => oc.n?.[0][1][2]);
// but parentheses end the chain, so what follows is evaluated
T('oc-paren-ends-chain', () => {
  try { return (oc.n?.a).b; } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('oc-paren-then-optional', () => (oc.n?.a)?.b);
T('oc-paren-then-call', () => {
  try { return (oc.n?.a)(); } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('oc-paren-then-index', () => {
  try { return (oc.n?.a)[0]; } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('oc-paren-nonnull-continues', () => (oc.a?.b).c);
T('oc-paren-nested-chain', () => {
  const outer = { inner: null };
  return (outer.inner?.x)?.y ?? 'both-short-circuited';
});
T('oc-undefined-vs-null', () => [undefined?.x, null?.x]);
T('oc-with-nullish', () => oc.missing?.deep ?? 'fallback');
T('oc-nonnull-falsy', () => {
  const o = { zero: 0, empty: '', f: false };
  return [o.zero?.toString(), o.empty?.length, o.f?.valueOf()];
});
T('oc-not-callable', () => {
  const o = { notFn: 5 };
  try { return o.notFn?.(); } catch (e) { return 'THROW:' + e.constructor.name; }
});
// delete through an optional chain still deletes; a nullish link abandons the
// whole operation and reports success, because there was nothing to remove
T('oc-delete', () => {
  const o = { a: 1 };
  const gone = delete o?.a;
  return [gone, 'a' in o, delete oc.n?.whatever];
});
T('oc-delete-index', () => {
  const o = { list: [1, 2, 3] };
  const gone = delete o.list?.[1];
  return [gone, 1 in o.list, o.list.length];
});
T('oc-delete-deep', () => {
  const o = { a: { b: { c: 1 } } };
  const gone = delete o.a?.b?.c;
  return [gone, 'c' in o.a.b];
});
T('oc-delete-shortcircuit-no-eval', () => {
  let keyReads = 0;
  const key = () => { keyReads++; return 'k'; };
  const nothing = null;
  const gone = delete nothing?.deep[key()];
  return [gone, keyReads];
});
// arguments after a short-circuit are never evaluated
T('oc-args-not-evaluated', () => {
  let calls = 0;
  const bump = () => { calls++; return 1; };
  const nothing = null;
  nothing?.method(bump(), bump());
  return calls;
});
T('oc-eval-once', () => {
  let reads = 0;
  const holder = { get o() { reads++; return { p: 1 }; } };
  const v = holder.o?.p;
  return [v, reads];
});

// --- nullish and logical ----------------------------------------------------

T('nullish-basics', () => [null ?? 'd', undefined ?? 'd', 0 ?? 'd', '' ?? 'd', false ?? 'd', NaN ?? 'd']);
T('nullish-shortcircuit', () => {
  let calls = 0;
  const rhs = () => { calls++; return 'r'; };
  const a = 'kept' ?? rhs();
  return [a, calls];
});
T('logical-return-operand', () => [0 || 'y', 1 && 'y', '' || null, 'a' && 0]);
T('logical-assign-and', () => {
  const o = { a: 1, b: 0 };
  o.a &&= 'set';
  o.b &&= 'skipped';
  return [o.a, o.b];
});
T('logical-assign-or', () => {
  const o = { a: 0, b: 5 };
  o.a ||= 'set';
  o.b ||= 'skipped';
  return [o.a, o.b];
});
T('logical-assign-nullish', () => {
  const o = { a: null, b: 0, c: undefined };
  o.a ??= 'set';
  o.b ??= 'skipped';
  o.c ??= 'set2';
  return [o.a, o.b, o.c];
});
// a logical assignment that short-circuits must not write at all
T('logical-assign-no-write', () => {
  const log = [];
  const o = {
    get p() { log.push('get'); return 'truthy'; },
    set p(v) { log.push('set'); },
  };
  o.p ??= 'never';
  o.p ||= 'never';
  return log.join(',');
});
T('logical-assign-does-write', () => {
  const log = [];
  const o = {
    get p() { log.push('get'); return null; },
    set p(v) { log.push('set:' + v); },
  };
  o.p ??= 'yes';
  return log.join(',');
});

// --- template literals ------------------------------------------------------

T('tpl-basic', () => { const n = 3; return `a${n}b${n + 1}c`; });
T('tpl-nested', () => { const x = 'X'; return `out${`in${x}`}er`; });
T('tpl-expr-types', () => `${null}|${undefined}|${[1, 2]}|${({})}|${true}`);
T('tpl-multiline', () => `l1
l2`);
T('tpl-escapes', () => `tab:\t nl:\n quote:\` dollar:\${} back:\\`);
T('tpl-tostring-called', () => {
  let calls = 0;
  const o = { toString() { calls++; return 'O'; } };
  const s = `${o}`;
  return [s, calls];
});
T('tpl-symbol-throws', () => {
  try { return `${Symbol('s')}`; } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('raw-basic', () => String.raw`a\nb\t${1 + 1}c`);
T('raw-backslash', () => String.raw`C:\Users\test`);
T('tagged-cooked-and-raw', () => {
  function tag(strings, ...vals) {
    return JSON.stringify({ cooked: strings.slice(), raw: strings.raw.slice(), vals });
  }
  return tag`a\n${1}b${2}`;
});
T('tagged-strings-is-array', () => {
  function tag(s) { return [Array.isArray(s), Array.isArray(s.raw), s.length, s.raw.length]; }
  return tag`x${1}y`;
});
T('tagged-frozen', () => {
  function tag(s) { return [Object.isFrozen(s), Object.isFrozen(s.raw)]; }
  return tag`a`;
});
T('tagged-no-subst', () => {
  function tag(s, ...v) { return [s.length, v.length, s[0]]; }
  return tag`just text`;
});
T('tagged-adjacent-subst', () => {
  function tag(s, ...v) { return [s.slice(), v]; }
  return tag`${1}${2}`;
});
T('tagged-member-this', () => {
  const holder = { name: 'H', tag(s) { return this.name + ':' + s[0]; } };
  return holder.tag`body`;
});

// --- spread -----------------------------------------------------------------

T('spread-call', () => Math.max(...[1, 5, 3]));
T('spread-call-mixed', () => {
  const f = (...a) => a;
  return f(0, ...[1, 2], 3, ...[4]);
});
T('spread-array-literal', () => [...[1, 2], 3, ...'ab']);
T('spread-holes-become-undefined', () => {
  const sparse = [1, , 3];
  const copy = [...sparse];
  return [copy.length, 1 in copy, copy[1]];
});
T('spread-set-map', () => [[...new Set([1, 1, 2])], [...new Map([['k', 'v']])]]);
T('spread-object', () => ({ ...{ a: 1 }, b: 2, ...{ a: 3 } }));
T('spread-object-primitives', () => [JSON.stringify({ ...'ab' }), JSON.stringify({ ...5 }), JSON.stringify({ ...null })]);
T('spread-object-getter-runs', () => {
  let calls = 0;
  const src = { get g() { calls++; return 1; } };
  const copy = { ...src };
  return [copy.g, calls, Object.getOwnPropertyDescriptor(copy, 'g').get === undefined];
});
T('spread-object-skips-proto', () => {
  const proto = { inherited: 1 };
  const o = Object.create(proto);
  o.own = 2;
  return JSON.stringify({ ...o });
});
T('spread-eval-order', () => {
  const log = [];
  const mk = (n) => ({ get [n]() { log.push(n); return n; } });
  const merged = { ...mk('a'), ...mk('b') };
  return log.join(',') + '|' + Object.keys(merged).join(',');
});
T('spread-non-iterable-call', () => {
  const f = (...a) => a;
  try { return f(...5); } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('spread-new', () => {
  class P { constructor(a, b) { this.sum = a + b; } }
  return new P(...[2, 3]).sum;
});

// --- compound assignment ----------------------------------------------------

T('compound-arith', () => {
  let n = 10;
  n += 5; n -= 3; n *= 2; n /= 4; n %= 4; n **= 2;
  return n;
});
T('compound-shift', () => {
  let n = -16;
  const a = n >> 2;
  const b = n >>> 28;
  const c = 1 << 31;
  return [a, b, c];
});
T('compound-string', () => { let s = 'a'; s += 1; s += null; return s; });
// the target's key is evaluated once, and read before the write
T('compound-key-once', () => {
  const log = [];
  const o = { x: 1 };
  const key = () => { log.push('key'); return 'x'; };
  o[key()] += 1;
  return [log.length, o.x];
});
T('compound-accessor-order', () => {
  const log = [];
  const o = {
    get v() { log.push('get'); return 1; },
    set v(x) { log.push('set:' + x); },
  };
  o.v += 10;
  return log.join(',');
});
T('incdec-prefix-postfix', () => {
  let a = 5;
  const post = a++;
  const pre = ++a;
  return [post, pre, a];
});
T('incdec-coerces', () => {
  let s = '5';
  s++;
  let u;
  const r = u++;
  return [s, typeof s, r, u];
});
T('incdec-bigint', () => { let b = 5n; b++; return b; });
T('incdec-property', () => {
  const o = { n: 1 };
  const arr = [10];
  o.n++; arr[0]--;
  return [o.n, arr[0]];
});

// --- arithmetic and bitwise edges -------------------------------------------

T('exp-right-assoc', () => 2 ** 3 ** 2);
T('exp-edges', () => [(-2) ** 2, 2 ** -1, 0 ** 0, (-8) ** (1 / 3)]);
T('div-mod-edges', () => [1 / 0, -1 / 0, 0 / 0, 5 % 3, -5 % 3, 5 % -3, 5.5 % 2]);
// -0 survives an integer multiply, which the tagged-integer representation
// cannot hold on its own, and orders below +0 in Math.min/max
T('negative-zero', () => [Object.is(-0, 0 * -1), Object.is(-0, -0), Object.is(0, -0), 1 / -0]);
T('negative-zero-sources', () => [
  Object.is(-0, -1 * 0), Object.is(-0, -2 * 0), Object.is(-0, 1.5 * 0 * -1),
  Object.is(-0, 0 / -1), Object.is(-0, -1 / Infinity), Object.is(-0, 2 * -0),
  Object.is(-0, Math.round(-0.4)), Object.is(-0, Math.trunc(-0.5)),
]);
T('negative-zero-minmax', () => [
  Object.is(-0, Math.min(0, -0)), Object.is(-0, Math.min(-0, 0)),
  Object.is(0, Math.max(0, -0)), Object.is(0, Math.max(-0, 0)),
  Math.min(1, -0), Math.max(-1, -0),
]);
T('bitwise-basics', () => [5 & 3, 5 | 3, 5 ^ 3, ~5]);
T('shift-count-mod32', () => [1 << 32, 1 << 33, 16 >> 33, -1 >>> 32]);
T('bitwise-coerces-to-int32', () => [2147483647 | 0, 2147483648 | 0, 4294967296 | 0, NaN | 0, 1.9 | 0, -1.9 | 0]);
T('unsigned-shift', () => [-1 >>> 0, -1 >>> 1, 2147483648 >>> 0]);
T('relational-strings', () => ['a' < 'b', 'Z' < 'a', '10' < '9', '' < 'a', 'abc' < 'abd']);
T('relational-nan', () => [NaN < 1, NaN > 1, NaN <= NaN, NaN >= NaN]);
T('relational-mixed', () => [1 < '2', '3' > 2, null >= 0, null > 0, undefined < 1]);
T('plus-vs-others', () => ['1' + 1, '1' - 1, '1' * '2', true + true, [] + [], [] + {}]);
T('comma-operator', () => {
  let side = 0;
  const v = (side++, side++, 'last');
  return [v, side];
});
T('void-operator', () => [void 0, void 'anything', typeof void 0]);

// --- typeof / delete / in ---------------------------------------------------

T('typeof-all', () => [typeof undefined, typeof null, typeof 0, typeof '', typeof true,
                       typeof 1n, typeof Symbol(), typeof {}, typeof [], typeof function () {}]);
T('typeof-undeclared', () => typeof notDeclaredAnywhere);
T('typeof-tdz', () => {
  try { const probe = () => typeof beforeLet; const r = probe(); let beforeLet = 1; return r; }
  catch (e) { return 'THROW:' + e.constructor.name; }
});
T('delete-property', () => {
  const o = { a: 1 };
  return [delete o.a, 'a' in o, delete o.neverThere];
});
T('delete-array-hole', () => {
  const a = [1, 2, 3];
  const r = delete a[1];
  return [r, a.length, 1 in a, a[1]];
});
T('delete-nonconfigurable', () => {
  const o = {};
  Object.defineProperty(o, 'fixed', { value: 1, configurable: false });
  try { return delete o.fixed; } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('delete-nonreference', () => [delete 5, delete (1 + 1)]);
T('in-operator', () => {
  const o = { own: 1 };
  return ['own' in o, 'toString' in o, 'missing' in o, 0 in [1], 1 in [1], 'length' in []];
});
T('in-non-object', () => {
  try { return 'x' in 'string'; } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('instanceof-basics', () => {
  class A {} class B extends A {}
  return [new B() instanceof B, new B() instanceof A, new A() instanceof B,
          [] instanceof Array, [] instanceof Object, 5 instanceof Number];
});

// --- switch -----------------------------------------------------------------

T('switch-strict-match', () => {
  function f(x) {
    switch (x) {
      case 1: return 'number';
      case '1': return 'string';
      default: return 'other';
    }
  }
  return [f(1), f('1'), f(true), f(null)];
});
T('switch-fallthrough', () => {
  const hit = [];
  switch (2) {
    case 1: hit.push(1);
    case 2: hit.push(2);
    case 3: hit.push(3); break;
    case 4: hit.push(4);
  }
  return hit;
});
T('switch-default-in-middle', () => {
  function f(x) {
    const hit = [];
    switch (x) {
      case 'a': hit.push('a'); break;
      default: hit.push('d');
      case 'b': hit.push('b'); break;
    }
    return hit.join(',');
  }
  return [f('a'), f('b'), f('zzz')];
});
T('switch-nan-never-matches', () => {
  switch (NaN) { case NaN: return 'matched'; default: return 'default'; }
});
T('switch-negative-zero', () => {
  switch (-0) { case 0: return 'zero'; default: return 'default'; }
});
T('switch-discriminant-once', () => {
  let calls = 0;
  const d = () => { calls++; return 2; };
  switch (d()) { case 1: break; case 2: break; case 3: break; }
  return calls;
});
T('switch-case-eval-order', () => {
  const log = [];
  const c = (n) => { log.push(n); return n; };
  switch (2) { case c(1): break; case c(2): break; case c(3): break; }
  return log.join(',');
});

console.log(out.join('\n'));

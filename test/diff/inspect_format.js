// What console.log prints. util.inspect is the same formatter, so most cases
// go through it to keep a case on one line.
//
// Node lays this out against a terminal width of 80: entries that fit go on
// one line, the rest go one per line, and a run of short array entries is
// laid out in columns. All three are checked here, since a formatter that
// only agrees on short values agrees on nothing that matters.
//
// Not checked: a rejected promise carrying an error, since that prints a
// stack with absolute paths and different frames.

const util = require('util');
const rows = [];
function T(label, fn) {
  let v;
  try { v = JSON.stringify(util.inspect(fn())); }
  catch (e) { v = 'THROW:' + (e && e.name ? e.name : String(e)); }
  rows.push(label + ' = ' + v);
}

// --- plain objects and depth ------------------------------------------------
T('empty-obj', () => ({}));
T('flat', () => ({ a: 1, b: 'two', c: true }));
T('nested-1', () => ({ a: { b: 1 } }));
T('nested-3', () => ({ a: { b: { c: { d: 1 } } } }));
T('nested-4', () => ({ a: { b: { c: { d: { e: 1 } } } } }));
T('undefined-null', () => ({ a: undefined, b: null }));
T('numeric-key', () => ({ 1: 'a' }));
T('quoted-key', () => ({ 'a-b': 1, 'ok': 2 }));
T('empty-key', () => ({ '': 1 }));
T('null-proto', () => Object.assign(Object.create(null), { a: 1 }));
T('object-create-proto', () => Object.create({ constructor: function Named() {} }));

// --- breaking to several lines ----------------------------------------------
T('seven-keys-fit', () => ({ k0: 'v', k1: 'v', k2: 'v', k3: 'v', k4: 'v', k5: 'v', k6: 'v' }));
T('eight-keys-break', () => ({ k0: 'v', k1: 'v', k2: 'v', k3: 'v', k4: 'v', k5: 'v', k6: 'v', k7: 'v' }));
T('many-keys', () => ({ alpha: 1, bravo: 2, charlie: 3, delta: 4, echo: 5, foxtrot: 6, golf: 7 }));
T('long-value-fits', () => ({ k: 'x'.repeat(60) }));
T('long-value-breaks', () => ({ k: 'x'.repeat(70) }));
T('nested-in-obj', () => ({ a: { b: 1, c: 2, d: 3, e: 4, f: 5, g: 6, h: 7 } }));
T('obj-with-long-nested', () => ({ key: { a: 'a'.repeat(30), b: 'b'.repeat(30) } }));
T('deep-indent', () => ({ l1: { l2: { m: 1, n: 2, o: 3, p: 4, q: 5, r: 6, s: 7, t: 8, u: 9 } } }));

// --- arrays -----------------------------------------------------------------
T('empty-arr', () => []);
T('arr-short', () => [1, 2, 3]);
T('arr-strings', () => ['a', 'b']);
T('arr-nested', () => [[1, [2, [3, [4]]]]]);
T('arr-holes', () => [1, , 3]);
T('arr-trailing-hole', () => { const a = [1]; a.length = 3; return a; });
T('arr-extra-prop', () => { const a = [1]; a.x = 2; return a; });
T('arr-of-objects', () => [{ a: 1 }, { b: 2 }]);
T('arr-objs-three', () => [{ a: 1, b: 2 }, { c: 3, d: 4 }, { e: 5, f: 6 }]);
T('arr-mixed', () => [1, 'two', { a: 1 }, [2], null, undefined, true]);
T('sparse-100', () => { const a = []; a[99] = 1; return a; });

// --- arrays laid out in columns ---------------------------------------------
T('arr-6-stays', () => [0, 1, 2, 3, 4, 5]);
T('arr-7-groups', () => [0, 1, 2, 3, 4, 5, 6]);
T('arr-9-groups', () => [0, 1, 2, 3, 4, 5, 6, 7, 8]);
T('arr-wide', () => Array.from({ length: 30 }, (_, i) => i));
T('arr-long', () => Array.from({ length: 120 }, (_, i) => i));
T('arr-101', () => Array.from({ length: 101 }, () => 1));
T('arr-strings-7', () => Array.from({ length: 7 }, (_, i) => 'str' + i));
T('arr-strings-12', () => Array.from({ length: 12 }, (_, i) => 'str' + i));
T('arr-strings-wide', () => ['aaaaaaaaaaaa', 'bbbbbbbbbbbb', 'cccccccccccc', 'dddddddddddd', 'eeeeeeeeeeee', 'ffffffffffff', 'gggggggggggg']);
T('arr-7-in-obj', () => ({ a: [1, 2, 3, 4, 5, 6, 7] }));
T('arr-in-arr', () => [[1, 2, 3, 4, 5, 6, 7]]);
T('arr-extra-many', () => { const a = [1, 2, 3, 4, 5, 6, 7]; a.zz = 1; return a; });

// --- collections ------------------------------------------------------------
T('map', () => new Map([['a', 1], ['b', 2]]));
T('map-empty', () => new Map());
T('map-object-key', () => new Map([[{ k: 1 }, [1, 2]]]));
T('map-12', () => new Map(Array.from({ length: 12 }, (_, i) => [i, i])));
T('set', () => new Set([1, 2, 3]));
T('set-empty', () => new Set());
T('set-12-no-columns', () => new Set(Array.from({ length: 12 }, (_, i) => i)));
T('set-120', () => new Set(Array.from({ length: 120 }, (_, i) => i)));
T('set-in-object', () => ({ m: new Set(['x']) }));
T('weakmap', () => new WeakMap());
T('weakset', () => new WeakSet());

// --- class instances --------------------------------------------------------
T('class-instance', () => { class Foo { constructor() { this.a = 1; } } return new Foo(); });
T('class-empty', () => { class Bare {} return new Bare(); });
T('class-nested', () => { class Inner { constructor() { this.x = 1; } } return { i: new Inner() }; });
T('class-extends', () => { class A {} class B extends A { constructor() { super(); this.b = 1; } } return new B(); });
T('tostringtag', () => ({ [Symbol.toStringTag]: 'Tagged', a: 1 }));
T('generator-object', () => (function* () {})());

// --- functions --------------------------------------------------------------
T('fn-named', () => function foo() {});
T('fn-anon', () => (function () {}));
T('fn-arrow-bound', () => { const f = () => {}; return f; });
T('fn-arrow-anon', () => (() => {}));
T('fn-class', () => { class Foo {} return Foo; });
T('fn-class-extends', () => { class A {} class B extends A {} return B; });
T('fn-async', () => (async function ay() {}));
T('fn-generator', () => (function* gee() {}));
T('fn-with-props', () => { function f() {} f.x = 1; return f; });
T('fn-in-object', () => ({ cb: function named() {} }));
T('builtin-fn', () => Math.max);

// --- special values ---------------------------------------------------------
T('date', () => new Date(0));
T('regexp', () => /ab+c/gi);
T('bigint', () => 10n);
T('negative-zero', () => -0);
T('nan-infinity', () => [NaN, Infinity, -Infinity]);
T('symbol', () => Symbol('s'));
T('symbol-key', () => { const o = {}; o[Symbol('k')] = 1; return o; });
T('symbol-value', () => ({ s: Symbol.iterator }));
T('boxed-number', () => new Number(5));
T('boxed-string', () => new String('ab'));
T('boxed-boolean', () => new Boolean(false));
T('promise-pending', () => new Promise(() => {}));
T('promise-resolved', () => Promise.resolve(7));
T('promise-object-value', () => Promise.resolve({ a: 1 }));
T('typed-array', () => new Uint8Array([1, 2, 3]));
T('typed-array-12', () => new Uint8Array(Array.from({ length: 12 }, (_, i) => i)));
T('typed-array-120', () => new Uint8Array(120));
T('array-buffer', () => new ArrayBuffer(2));
T('proxy', () => new Proxy({ a: 1 }, {}));
T('proxy-array', () => new Proxy([1, 2], {}));

// --- strings ----------------------------------------------------------------
T('str-plain', () => 'hello');
T('str-apostrophe', () => "it's");
T('str-both-quotes', () => `it's a "quote"`);
T('str-newline', () => 'a\nb');
T('str-tab-escape', () => 'a\tb\\c');
T('str-control', () => 'a' + String.fromCharCode(7) + 'b' + String.fromCharCode(27) + 'c');
T('str-unicode', () => 'café \u{1F600}');
T('str-in-array', () => ['a\nb']);
T('str-truncated', () => 'x'.repeat(10001));

// --- accessors and hidden properties ----------------------------------------
T('getter', () => ({ get a() { return 1; } }));
T('getter-setter', () => ({ get a() { return 1; }, set a(v) {} }));
T('setter-only', () => ({ set a(v) {} }));
T('non-enumerable', () => { const o = { a: 1 }; Object.defineProperty(o, 'hidden', { value: 2 }); return o; });

// --- circular ---------------------------------------------------------------
T('circular-self', () => { const o = { a: 1 }; o.self = o; return o; });
T('circular-array', () => { const a = [1]; a.push(a); return a; });
T('circular-nested', () => { const o = { a: {} }; o.a.back = o; return o; });
T('circular-two', () => { const a = { n: 'a' }; const b = { n: 'b' }; a.b = b; b.a = a; return [a, b]; });
T('shared-not-circular', () => { const s = { x: 1 }; return { a: s, b: s }; });

// --- own key order, which the printed order follows -------------------------
T('key-order-symbols-last', () => {
  const s = Symbol('s');
  const o = { [s]: 1, b: 2, 1: 3, a: 4 };
  return Reflect.ownKeys(o).map(String).join(',');
});
T('key-order-assign', () => {
  const s = Symbol('s');
  return Object.keys(Object.assign({}, { [s]: 1, z: 2, 0: 3 })).join(',');
});

// --- what console.log itself does -------------------------------------------
const log = [];
const say = (...a) => log.push(a);
console.log(rows.join('\n'));
console.log('bare string, unquoted');
console.log('two', 'args', 1, true, null, undefined);
console.log({ a: 1 }, [1, 2]);
console.log();
console.log('nested %s and %d', 'x', 5);
console.log([1, [2, [3, [4, [5]]]]]);

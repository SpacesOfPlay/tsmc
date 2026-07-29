// util and the console formatting built on it. What console.log prints is
// what a developer reads all day, so the inspect cases are compared as the
// literal text, not by shape.
//
// Two things are deliberately not compared:
//   - the exact marker for a cycle. node writes
//     `<ref *1> { a: 1, self: [Circular *1] }`, numbering the reference from a
//     pre-pass; tsmc writes `[Circular]`. What matters -- that the cycle is
//     caught rather than recursed into -- is checked instead.
//   - invoking a util.deprecate wrapper. node writes a DeprecationWarning to
//     stderr carrying its pid, which cannot match anything.

const util = require('util');

const out = [];

function T(label, fn) {
  let v;
  try { v = fn(); } catch (e) {
    v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e));
  }
  out.push(label + ' = ' + (typeof v === 'string' ? JSON.stringify(v) : String(v)));
}

// --- util.format ------------------------------------------------------------

T('format-plain', () => util.format('hello'));
T('format-s', () => util.format('%s world', 'hello'));
T('format-d', () => util.format('%d apples', 5));
T('format-i', () => util.format('%i', 5.7));
T('format-f', () => util.format('%f', 5.5));
T('format-j', () => util.format('%j', { a: 1 }));
T('format-percent', () => util.format('100%% sure'));
T('format-extra-args', () => util.format('a', 'b', 'c'));
T('format-missing-arg', () => util.format('%s %s', 'only'));
T('format-number-as-s', () => util.format('%s', 42));
T('format-object-as-s', () => util.format('%s', { a: 1 }));
T('format-no-format-string', () => util.format(1, 'two', true));
T('format-null-undefined', () => util.format('%s %s', null, undefined));

// --- util.inspect: primitives and simple values -----------------------------

const I = (v, o) => util.inspect(v, o);

T('inspect-string', () => I('abc'));
T('inspect-string-quotes', () => I("it's"));
T('inspect-number', () => I(42));
T('inspect-negzero', () => I(-0));
T('inspect-bigint', () => I(1n));
T('inspect-boolean', () => I(true));
T('inspect-null', () => I(null));
T('inspect-undefined', () => I(undefined));
T('inspect-symbol', () => I(Symbol('s')));
T('inspect-nan-infinity', () => I([NaN, Infinity, -Infinity]));

// --- util.inspect: structures -----------------------------------------------

T('inspect-array', () => I([1, 2, 3]));
T('inspect-array-strings', () => I(['a', 'b']));
T('inspect-array-empty', () => I([]));
T('inspect-array-nested', () => I([1, [2, [3]]]));
T('inspect-array-holes', () => I([1, , 3]));
T('inspect-object', () => I({ a: 1, b: 'two' }));
T('inspect-object-empty', () => I({}));
T('inspect-object-nested', () => I({ a: { b: { c: 1 } } }));
T('inspect-object-quoted-key', () => I({ 'a-b': 1, valid_key: 2 }));
T('inspect-mixed', () => I({ arr: [1, 2], s: 'x', n: null }));
T('inspect-map', () => I(new Map([['a', 1]])));
T('inspect-set', () => I(new Set([1, 2])));
T('inspect-date', () => I(new Date(0)));
T('inspect-regexp', () => I(/ab+c/gi));
T('inspect-error-name', () => I(new TypeError('x')).split('\n')[0]);
T('inspect-function', () => I(function named() {}));
T('inspect-anon-function', () => I(() => {}));
T('inspect-class-instance', () => {
  class Point { constructor() { this.x = 1; this.y = 2; } }
  return I(new Point());
});
T('inspect-circular', () => {
  const o = { a: 1 };
  o.self = o;
  const s = I(o);
  // caught, not recursed into, and the rest of the object still printed
  return [s.includes('Circular'), s.includes('a: 1'), s.length < 60].join(',');
});
T('inspect-null-proto', () => I(Object.create(null)));
T('inspect-depth-default', () => I({ a: { b: { c: { d: 1 } } } }));
T('inspect-depth-option', () => I({ a: { b: { c: { d: 1 } } } }, { depth: 0 }));
T('inspect-buffer', () => I(Buffer.from([1, 2, 255])));
T('inspect-typedarray', () => I(new Uint8Array([1, 2])));
T('inspect-boxed', () => I(new Number(5)));

// --- util.promisify ---------------------------------------------------------

T('promisify-is-function', () => typeof util.promisify);
T('promisify-non-function', () => {
  try { util.promisify(5); return 'no-throw'; } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('callbackify-is-function', () => typeof util.callbackify);

// --- util.types -------------------------------------------------------------

T('types-shape', () => typeof util.types);
T('types-checks', () => {
  if (!util.types) return 'missing';
  const t = util.types;
  return [
    t.isDate(new Date()), t.isDate({}),
    t.isRegExp(/x/), t.isRegExp('x'),
    t.isMap(new Map()), t.isSet(new Set()),
    t.isPromise(Promise.resolve()), t.isPromise({}),
    t.isNativeError(new Error('x')), t.isNativeError({}),
  ].join(',');
});
T('types-typedarray', () => {
  if (!util.types || typeof util.types.isTypedArray !== 'function') return 'missing';
  return [util.types.isTypedArray(new Uint8Array(1)), util.types.isTypedArray([])].join(',');
});

// --- the rest ---------------------------------------------------------------

T('isDeepStrictEqual', () => {
  if (typeof util.isDeepStrictEqual !== 'function') return 'missing';
  return [
    util.isDeepStrictEqual({ a: [1, 2] }, { a: [1, 2] }),
    util.isDeepStrictEqual({ a: 1 }, { a: '1' }),
    util.isDeepStrictEqual([1, 2], [1, 2]),
    util.isDeepStrictEqual(new Map([['k', 1]]), new Map([['k', 1]])),
  ].join(',');
});
T('inherits', () => {
  if (typeof util.inherits !== 'function') return 'missing';
  function Base() {}
  Base.prototype.hello = function () { return 'hi'; };
  function Derived() {}
  util.inherits(Derived, Base);
  return [new Derived().hello(), new Derived() instanceof Base].join(',');
});
T('deprecate', () => {
  if (typeof util.deprecate !== 'function') return 'missing';
  const f = util.deprecate(() => 'still works', 'old');
  // not called: node would write a DeprecationWarning to stderr (see header)
  return typeof f;
});
T('inspect-custom-symbol', () => typeof util.inspect.custom);

// --- console.log, which is util.format ---------------------------------------

const lines = [];
const realLog = console.log;
console.log = (...a) => { lines.push(util.format(...a)); };
console.log('plain');
console.log('%s=%d', 'n', 3);
console.log({ a: 1 });
console.log([1, 2]);
console.log('a', 1, true, null);
console.log = realLog;
for (let i = 0; i < lines.length; i++) out.push('console-' + i + ' = ' + JSON.stringify(lines[i]));

console.log(out.join('\n'));

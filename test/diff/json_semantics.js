// JSON.stringify and JSON.parse: what each value type serializes to, toJSON,
// the replacer in both forms, indentation, and the parse grammar — which is
// stricter than JavaScript's — along with the reviver.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// --- stringify: primitives and shapes ---
T('str-primitives', () => [JSON.stringify(1), JSON.stringify('a'), JSON.stringify(true), JSON.stringify(null)]);
T('str-undefined', () => JSON.stringify(undefined));
T('str-function', () => JSON.stringify(function () {}));
T('str-symbol', () => JSON.stringify(Symbol('s')));
T('str-nested', () => JSON.stringify({ a: [1, { b: 2 }] }));
T('str-empty', () => [JSON.stringify({}), JSON.stringify([])]);
T('str-in-object-dropped', () => JSON.stringify({ a: undefined, b: function () {}, c: Symbol('s'), d: 1 }));
T('str-in-array-nulled', () => JSON.stringify([undefined, function () {}, Symbol('s'), 1]));
T('str-nonfinite', () => JSON.stringify([Infinity, -Infinity, NaN]));
T('str-neg-zero', () => JSON.stringify(-0));
T('str-large-number', () => JSON.stringify(1e21));
T('str-string-escapes', () => JSON.stringify('a"b\\c\nd\tef'));
T('str-unicode', () => JSON.stringify('é☃'));
T('str-lone-surrogate', () => JSON.stringify('\ud800'));
T('str-boxed', () => JSON.stringify([new Number(5), new String('s'), new Boolean(true)]));
T('str-date', () => JSON.stringify(new Date(0)));
T('str-regexp', () => JSON.stringify(/x/g));
T('str-map-set', () => [JSON.stringify(new Map([['a', 1]])), JSON.stringify(new Set([1]))]);
T('str-bigint-throws', () => JSON.stringify({ a: 1n }));
T('str-circular-throws', () => { const o = {}; o.self = o; return JSON.stringify(o); });
T('str-circular-array', () => { const a = []; a.push(a); return JSON.stringify(a); });
T('str-repeated-not-circular', () => { const shared = { x: 1 }; return JSON.stringify([shared, shared]); });
T('str-holes', () => JSON.stringify([1, , 3]));
T('str-nonenumerable-skipped', () => { const o = { a: 1 }; Object.defineProperty(o, 'h', { value: 2 }); return JSON.stringify(o); });
T('str-symbol-key-skipped', () => JSON.stringify({ [Symbol('k')]: 1, a: 2 }));
T('str-proto-not-included', () => { const o = Object.create({ inherited: 1 }); o.own = 2; return JSON.stringify(o); });
T('str-getter-invoked', () => { let n = 0; const o = { get a() { n++; return 1; } }; const s = JSON.stringify(o); return [s, n]; });
T('str-null-proto', () => JSON.stringify(Object.create(null, { a: { value: 1, enumerable: true } })));

// --- toJSON ---
T('tojson-object', () => JSON.stringify({ toJSON() { return 'custom'; } }));
T('tojson-nested', () => JSON.stringify({ a: { toJSON() { return 1; } } }));
T('tojson-receives-key', () => { let got; JSON.stringify({ a: { toJSON(k) { got = k; return 1; } } }); return got; });
T('tojson-top-level-key', () => { let got; JSON.stringify({ toJSON(k) { got = k; return 1; } }); return JSON.stringify(got); });
T('tojson-not-function', () => JSON.stringify({ toJSON: 5, a: 1 }));
T('tojson-returns-undefined', () => JSON.stringify({ a: { toJSON() { return undefined; } } }));

// --- replacer ---
T('replacer-fn', () => JSON.stringify({ a: 1, b: 2 }, (k, v) => typeof v === 'number' ? v * 2 : v));
T('replacer-fn-drop', () => JSON.stringify({ a: 1, b: 2 }, (k, v) => k === 'b' ? undefined : v));
T('replacer-fn-root-key', () => { const keys = []; JSON.stringify({ a: 1 }, (k, v) => { keys.push(k); return v; }); return keys; });
T('replacer-fn-this', () => { let got; JSON.stringify({ a: 1 }, function (k, v) { if (k === 'a') got = this.a; return v; }); return got; });
T('replacer-array', () => JSON.stringify({ a: 1, b: 2, c: 3 }, ['a', 'c']));
T('replacer-array-order', () => JSON.stringify({ a: 1, b: 2 }, ['b', 'a']));
T('replacer-array-nested', () => JSON.stringify({ a: { a: 1, b: 2 }, b: 3 }, ['a']));
T('replacer-array-numbers', () => JSON.stringify({ 1: 'x', 2: 'y' }, [1]));
T('replacer-array-ignored-for-arrays', () => JSON.stringify([1, 2], ['0']));
T('replacer-non-callable', () => JSON.stringify({ a: 1 }, 5));

// --- space ---
T('space-number', () => JSON.stringify({ a: 1 }, null, 2));
T('space-nested', () => JSON.stringify({ a: { b: 1 } }, null, 2));
T('space-array', () => JSON.stringify([1, 2], null, 2));
T('space-string', () => JSON.stringify({ a: 1 }, null, '--'));
T('space-clamped', () => JSON.stringify({ a: 1 }, null, 20).length);
T('space-zero', () => JSON.stringify({ a: 1 }, null, 0));
T('space-empty-containers', () => JSON.stringify({ a: {}, b: [] }, null, 2));

// --- parse ---
T('parse-primitives', () => [JSON.parse('1'), JSON.parse('"a"'), JSON.parse('true'), JSON.parse('null')]);
T('parse-nested', () => JSON.parse('{"a":[1,{"b":2}]}'));
T('parse-whitespace', () => JSON.parse('  {  "a" : 1 }  ').a);
T('parse-escapes', () => JSON.parse('"a\\nb\\tc\\"d\\\\e"'));
T('parse-unicode-escape', () => JSON.parse('"\\u00e9"'));
T('parse-surrogate-pair', () => JSON.parse('"\\ud83d\\ude00"').length);
T('parse-numbers', () => [JSON.parse('1.5'), JSON.parse('-1'), JSON.parse('1e3'), JSON.parse('1E-3')]);
T('parse-big-number', () => JSON.parse('123456789012345678901234567890'));
T('parse-empty-throws', () => JSON.parse(''));
T('parse-trailing-comma', () => JSON.parse('[1,]'));
T('parse-single-quotes', () => JSON.parse("{'a':1}"));
T('parse-unquoted-key', () => JSON.parse('{a:1}'));
T('parse-nan', () => JSON.parse('NaN'));
T('parse-undefined', () => JSON.parse('undefined'));
T('parse-leading-zero', () => JSON.parse('01'));
T('parse-leading-plus', () => JSON.parse('+1'));
T('parse-hex', () => JSON.parse('0x10'));
T('parse-trailing-garbage', () => JSON.parse('1 2'));
T('parse-duplicate-keys', () => JSON.stringify(JSON.parse('{"a":1,"a":2}')));
T('parse-non-string-arg', () => [JSON.parse(1), JSON.parse(true)]);
T('parse-key-order', () => Object.keys(JSON.parse('{"b":1,"2":2,"a":3,"1":4}')));

// --- reviver ---
T('reviver-doubles', () => JSON.parse('{"a":1,"b":2}', (k, v) => typeof v === 'number' ? v * 2 : v));
T('reviver-drop', () => JSON.stringify(JSON.parse('{"a":1,"b":2}', (k, v) => k === 'b' ? undefined : v)));
T('reviver-order', () => { const keys = []; JSON.parse('{"a":{"b":1}}', (k, v) => { keys.push(k); return v; }); return keys; });
T('reviver-root-key', () => { let last; JSON.parse('1', (k, v) => { last = k; return v; }); return JSON.stringify(last); });
T('reviver-this', () => { let got; JSON.parse('{"a":1}', function (k, v) { if (k === 'a') got = typeof this; return v; }); return got; });
T('reviver-array', () => JSON.parse('[1,2]', (k, v) => Array.isArray(v) ? v : v * 10));

console.log(rows.join('\n'));

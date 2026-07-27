// Destructuring: object patterns, nesting, defaults, rest, and the
// assignment-expression form, in declarations and parameters alike.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// Object patterns.
T('obj-basic', () => { const { a, b } = { a: 1, b: 2 }; return [a, b]; });
T('obj-rename', () => { const { a: x } = { a: 1 }; return x; });
T('obj-missing', () => { const { z } = {}; return z; });
T('obj-default', () => { const { z = 5 } = {}; return z; });
T('obj-default-not-used', () => { const { z = 5 } = { z: 1 }; return z; });
T('obj-default-undefined', () => { const { z = 5 } = { z: undefined }; return z; });
T('obj-default-null', () => { const { z = 5 } = { z: null }; return z; });
T('obj-rename-default', () => { const { a: x = 9 } = {}; return x; });
T('obj-rest', () => { const { a, ...r } = { a: 1, b: 2, c: 3 }; return [a, r]; });
T('obj-rest-empty', () => { const { a, ...r } = { a: 1 }; return [a, r]; });
T('obj-computed-key', () => { const k = 'a'; const { [k]: v } = { a: 7 }; return v; });
T('obj-computed-default', () => { const k = 'z'; const { [k]: v = 3 } = {}; return v; });
T('obj-from-string', () => { const { length } = 'abc'; return length; });
T('obj-from-array', () => { const { 0: first, length } = [7, 8]; return [first, length]; });
T('obj-inherited', () => { const proto = { p: 1 }; const { p } = Object.create(proto); return p; });
T('obj-getter-invoked', () => { let n = 0; const src = { get g() { n++; return 1; } }; const { g } = src; return [g, n]; });
T('obj-null-throws', () => { const { a } = null; });
T('obj-undefined-throws', () => { const { a } = undefined; });

// Nesting.
T('nested-obj', () => { const { a: { b } } = { a: { b: 1 } }; return b; });
T('nested-obj-default', () => { const { a: { b } = { b: 2 } } = {}; return b; });
T('nested-mixed', () => { const { a: [x, { y }] } = { a: [1, { y: 2 }] }; return [x, y]; });
T('nested-array-obj', () => { const [{ a }, { b }] = [{ a: 1 }, { b: 2 }]; return [a, b]; });
T('deep-nesting', () => { const { a: { b: { c: { d } } } } = { a: { b: { c: { d: 'deep' } } } }; return d; });
T('nested-missing-throws', () => { const { a: { b } } = {}; });

// Array patterns alongside them.
T('ary-basic', () => { const [a, b] = [1, 2]; return [a, b]; });
T('ary-skip', () => { const [, b] = [1, 2]; return b; });
T('ary-default', () => { const [a = 5] = []; return a; });
T('ary-rest', () => { const [a, ...r] = [1, 2, 3]; return [a, r]; });
T('ary-swap', () => { let a = 1, b = 2; [a, b] = [b, a]; return [a, b]; });
T('ary-from-string', () => { const [a, b] = 'xy'; return [a, b]; });
T('ary-past-end', () => { const [a, b] = [1]; return [a, b]; });

// The assignment form (no declaration).
T('assign-obj', () => { let a; ({ a } = { a: 1 }); return a; });
T('assign-obj-rename', () => { let x; ({ a: x } = { a: 2 }); return x; });
T('assign-obj-default', () => { let a; ({ a = 3 } = {}); return a; });
T('assign-nested', () => { let b; ({ a: { b } } = { a: { b: 4 } }); return b; });
T('assign-to-member', () => { const o = {}; ({ a: o.x } = { a: 5 }); return o.x; });
T('assign-to-index', () => { const o = []; [o[0]] = [6]; return o[0]; });
T('assign-rest', () => { let a, r; ({ a, ...r } = { a: 1, b: 2 }); return [a, r]; });
T('assign-returns-value', () => { let a; const v = ({ a } = { a: 7 }); return [a, v]; });

// Parameters.
T('param-obj', () => { function f({ a, b }) { return [a, b]; } return f({ a: 1, b: 2 }); });
T('param-obj-default', () => { function f({ a = 9 } = {}) { return a; } return [f(), f({}), f({ a: 1 })]; });
T('param-ary', () => { function f([a, b]) { return [a, b]; } return f([1, 2]); });
T('param-nested', () => { function f({ a: { b } }) { return b; } return f({ a: { b: 3 } }); });
T('param-rest-pattern', () => { function f(...[a, b]) { return [a, b]; } return f(1, 2); });
T('param-mixed', () => { function f(a, { b }, [c]) { return [a, b, c]; } return f(1, { b: 2 }, [3]); });
T('param-default-refs-earlier', () => { function f(a, { b = a } = {}) { return b; } return f(5); });
T('param-arrow-obj', () => { const f = ({ a }) => a; return f({ a: 8 }); });
T('param-missing-throws', () => { function f({ a }) { return a; } return f(); });

// for-of and catch.
T('for-of-obj', () => { const o = []; for (const { a } of [{ a: 1 }, { a: 2 }]) o.push(a); return o; });
T('for-of-entries', () => { const o = []; for (const [k, v] of Object.entries({ x: 1 })) o.push(k + v); return o; });
T('for-of-nested', () => { const o = []; for (const { a: [b] } of [{ a: [1] }]) o.push(b); return o; });
T('catch-destructure', () => { try { throw { code: 1, msg: 'm' }; } catch ({ code, msg }) { return [code, msg]; } });

// Evaluation order and side effects.
T('default-evaluated-lazily', () => { let n = 0; const inc = () => ++n; const { a = inc() } = { a: 1 }; return [a, n]; });
T('default-evaluated-when-missing', () => { let n = 0; const inc = () => ++n; const { a = inc() } = {}; return [a, n]; });
T('key-order', () => { const order = []; const k = (s) => { order.push(s); return s; }; const { [k('one')]: a, [k('two')]: b } = { one: 1, two: 2 }; return order; });

console.log(rows.join('\n'));

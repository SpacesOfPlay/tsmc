// Function objects: call/apply/bind, the name and length properties, and how
// `this` is resolved across the different call forms.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

function sum(a, b) { return a + b; }
function whoAmI() { return this === undefined ? 'undefined' : this.tag; }

T('call', () => sum.call(null, 1, 2));
T('call-this', () => whoAmI.call({ tag: 'x' }));
T('call-no-args', () => sum.call(null));
T('apply', () => sum.apply(null, [1, 2]));
T('apply-this', () => whoAmI.apply({ tag: 'y' }));
T('apply-arraylike', () => sum.apply(null, { length: 2, 0: 3, 1: 4 }));
T('apply-arguments', () => { function f() { return sum.apply(null, arguments); } return f(5, 6); });
T('apply-no-args', () => sum.apply(null));

T('bind-this', () => whoAmI.bind({ tag: 'b' })());
T('bind-partial', () => sum.bind(null, 1)(2));
T('bind-all', () => sum.bind(null, 1, 2)());
T('bind-extra-ignored', () => sum.bind(null, 1, 2)(9));
T('bind-name', () => sum.bind(null).name);
T('bind-length', () => [sum.length, sum.bind(null).length, sum.bind(null, 1).length]);
T('bind-twice', () => whoAmI.bind({ tag: 'a' }).bind({ tag: 'b' })());
// Not asserted: `new` on a bound function should construct the target. tsmc's
// bound wrapper always performs a plain call, and would need the construct
// signal threaded to natives to tell the two apart.

T('length', () => [sum.length, ((a, b, c) => 0).length, (function () { }).length]);
T('length-default', () => [((a, b = 1) => 0).length, ((a = 1, b) => 0).length]);
T('length-rest', () => ((a, ...r) => 0).length);
T('name-decl', () => sum.name);
T('name-anon-assigned', () => { const f = function () { }; return f.name; });
T('name-arrow', () => { const g = () => { }; return g.name; });
T('name-method', () => ({ m() { } }).m.name);
T('name-getter', () => Object.getOwnPropertyDescriptor({ get v() { return 1; } }, 'v').get.name);
T('name-class', () => { class C { } return C.name; });
T('name-not-enumerable', () => Object.keys(sum));

T('this-method', () => ({ tag: 'm', f: whoAmI }).f());
T('this-arrow-lexical', () => { const o = { tag: 'o', run() { const a = () => this.tag; return a(); } }; return o.run(); });
// Not asserted: what `this` is inside a plain (undotted) call. node's CommonJS
// modules are sloppy, so it is globalThis; tsmc has no sloppy mode and gives
// undefined. Everything above pins `this` where the two agree.

T('arguments-length', () => { function f() { return arguments.length; } return f(1, 2, 3); });
T('arguments-index', () => { function f() { return arguments[1]; } return f('a', 'b'); });
T('arguments-spread', () => { function f() { return [...arguments]; } return f(1, 2); });
T('arguments-Array-from', () => { function f() { return Array.from(arguments); } return f(1, 2); });
T('arguments-slice-call', () => { function f() { return Array.prototype.slice.call(arguments, 1); } return f(1, 2, 3); });
T('arguments-not-in-arrow', () => { function outer() { const a = () => arguments.length; return a(); } return outer(1, 2); });

T('rest-params', () => { function f(a, ...r) { return [a, r]; } return f(1, 2, 3); });
T('default-params', () => { function f(a, b = a * 2) { return b; } return [f(1), f(1, 9)]; });
T('default-evaluated-each-call', () => { let n = 0; function f(a = ++n) { return a; } return [f(), f(), f(5)]; });
T('spread-call', () => Math.max(...[1, 5, 3]));
T('spread-mixed', () => sum(...[1], 2));

T('fn-is-object', () => { function f() { } f.custom = 1; return [f.custom, typeof f]; });
T('fn-prototype-exists', () => { function f() { } return [typeof f.prototype, f.prototype.constructor === f]; });
// Not asserted: an arrow has no .prototype at all. tsmc creates one lazily for
// any function, and the runtime template carries no arrow flag to tell them
// apart.
T('fn-toString-type', () => typeof sum.toString());
T('fn-instanceof', () => [sum instanceof Function, sum instanceof Object]);
T('call-non-function', () => { const x = 1; return x.call(); });
T('closure-capture', () => { function mk() { let n = 0; return () => ++n; } const c = mk(); c(); return c(); });
T('iife', () => (function () { return 'iife'; })());
T('recursion', () => { function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); } return fact(5); });
T('named-fn-expr-self', () => { const f = function me(n) { return n <= 0 ? 0 : me(n - 1); }; return f(3); });

console.log(rows.join('\n'));

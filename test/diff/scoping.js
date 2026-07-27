// Scoping: hoisting, the temporal dead zone, block and loop bindings, and
// what closures actually capture.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// Hoisting.
T('var-hoisted-undefined', () => { return [typeof x, (function () { var x = 1; return x; })()]; var x; });
T('function-hoisted', () => { return [typeof h, h()]; function h() { return 1; } });
T('function-over-var', () => { var f; return typeof f; function f() { } });
T('var-in-block-escapes', () => { { var v = 1; } return v; });
T('let-in-block-contained', () => { { let l = 1; } return typeof l; });
T('var-redeclare-keeps-value', () => { var a = 1; var a; return a; });

// Temporal dead zone.
T('tdz-let', () => { try { x; } catch (e) { return e.constructor.name; } let x; });
T('tdz-const', () => { try { c; } catch (e) { return e.constructor.name; } const c = 1; });
T('tdz-class', () => { try { new C(); } catch (e) { return e.constructor.name; } class C { } });
T('tdz-typeof', () => { try { return typeof z; } catch (e) { return e.constructor.name; } let z; });
T('tdz-ends-at-init', () => { let y = 1; return y; });
T('tdz-in-block', () => { let o = 'outer'; { try { return o; } catch (e) { return e.constructor.name; } let o; } });

// const. Not asserted: reassigning one. node raises a TypeError when the
// assignment runs, while tsmc rejects it at compile time, which is stricter
// but stops the whole file rather than the one case.
T('const-mutate-object', () => { const o = { a: 1 }; o.a = 2; return o.a; });
T('const-in-loop', () => { const r = []; for (const v of [1, 2]) r.push(v); return r; });

// Block scoping and shadowing.
T('shadow-block', () => { let s = 'outer'; { let s = 'inner'; } return s; });
T('shadow-nested-read', () => { let s = 'outer'; let got; { let s = 'inner'; got = s; } return [got, s]; });
T('shadow-param', () => { function f(p) { { let p = 'inner'; return p; } } return f('outer'); });
// Not asserted: whether a function declared inside a block is also visible
// outside it. That is a sloppy-mode web-compatibility rule; tsmc scopes such a
// declaration to its block, as strict mode and modules do.
T('if-block-let', () => { if (true) { let i = 1; } return typeof i; });

// Loop bindings and closures.
T('closure-let-per-iteration', () => { const f = []; for (let i = 0; i < 3; i++) f.push(() => i); return f.map((g) => g()); });
T('closure-var-shared', () => { const f = []; for (var i = 0; i < 3; i++) f.push(() => i); return f.map((g) => g()); });
T('closure-for-of-let', () => { const f = []; for (const v of [1, 2]) f.push(() => v); return f.map((g) => g()); });
T('closure-captures-reference', () => { let n = 1; const g = () => n; n = 2; return g(); });
T('closure-counter', () => { function mk() { let n = 0; return () => ++n; } const c = mk(); c(); c(); return c(); });
T('closure-independent', () => { function mk() { let n = 0; return () => ++n; } const a = mk(); const b = mk(); a(); return [a(), b()]; });
T('iife-scope', () => { const r = (function () { var priv = 'p'; return priv; })(); return [r, typeof priv]; });
T('nested-closure', () => { function o() { let x = 1; return function () { return function () { return x; }; }; } return o()()(); });

// Function declarations and expressions.
T('named-fn-expr-not-leaked', () => { const f = function inner() { return typeof inner; }; return [f(), typeof inner]; });
T('fn-expr-not-hoisted', () => { const t = typeof g; var g = function () { }; return t; });
T('arrow-no-own-this', () => { const o = { v: 1, m() { return (() => this.v)(); } }; return o.m(); });
T('arrow-no-arguments', () => { function outer() { const a = () => arguments[0]; return a(); } return outer('x'); });

// Catch parameter scope.
T('catch-param-scoped', () => { let e = 'outer'; try { throw 'thrown'; } catch (e) { } return e; });
T('catch-param-visible', () => { try { throw 'thrown'; } catch (e) { return e; } });
T('catch-block-let', () => { try { throw 1; } catch (e) { let inner = 2; return inner; } });

// Module/script level.
T('global-function-call', () => { function top() { return 'top'; } return top(); });
T('recursive-block-fn', () => { { function r(n) { return n <= 0 ? 0 : r(n - 1); } return r(3); } });
T('const-fn-recursion', () => { const f = (n) => n <= 0 ? 0 : f(n - 1); return f(3); });

// Assignment before declaration in the same scope.
T('assign-to-var-hoisted', () => { x = 5; var x; return x; });
T('reassign-let-after-init', () => { let y = 1; y = 2; return y; });

console.log(rows.join('\n'));

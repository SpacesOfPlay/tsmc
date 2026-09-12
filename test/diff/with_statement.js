// The `with` statement: a scope whose bindings are an object's properties.
// The object is consulted first, Symbol.unscopables can hide a name from it,
// a name it does not have falls through to the enclosing scope, and the scope
// is lexical -- a function defined in the body keeps resolving against it.

const T = (l, f) => { try { console.log(l, '->', String(f())); } catch (e) { console.log(l, 'threw', e.constructor.name); } };
T('read a property', () => { const o = { a: 1 }; with (o) { return a; } });
T('a name the object lacks', () => { var b = 2; const o = { a: 1 }; with (o) { return b; } });
T('write a property', () => { const o = { a: 1 }; with (o) { a = 5; } return o.a; });
T('write a name it lacks', () => { var c = 1; const o = {}; with (o) { c = 7; } return c + ',' + ('c' in o); });
T('typeof', () => { const o = { a: 1 }; with (o) { return [typeof a, typeof zzz].join(','); } });
T('delete', () => { const o = { a: 1 }; let r; with (o) { r = delete a; } return [r, 'a' in o].join(','); });
T('a method takes the object as this', () => { const o = { n: 3, m() { return this.n; } }; with (o) { return m(); } });
T('a closure keeps the scope', () => { const o = { a: 1 }; let f; with (o) { f = () => a; } o.a = 9; return f(); });
T('a function declared inside', () => { const o = { a: 1 }; let f; with (o) { f = function () { return a; }; } return f(); });
T('a local shadows it', () => { const o = { a: 1 }; with (o) { let a = 2; return a; } });
T('nested with, inner wins', () => { const o = { a: 1 }; const p = { a: 2 }; with (o) { with (p) { return a; } } });
T('nested with, outer answers', () => { const o = { a: 1 }; const p = { b: 2 }; with (o) { with (p) { return a; } } });
T('the prototype chain answers', () => { const o = Object.create({ a: 4 }); with (o) { return a; } });
T('a getter runs', () => { let n = 0; const o = { get a() { n++; return 8; } }; with (o) { a; a; } return n; });
T('a setter runs', () => { let got = 0; const o = { set a(v) { got = v; } }; with (o) { a = 3; } return got; });
T('null throws', () => { with (null) { return 1; } });
T('undefined throws', () => { with (undefined) { return 1; } });
T('a primitive is boxed', () => { with ('abc') { return length; } });
T('unscopables hides a name', () => { var keys = 'outer'; const o = { keys: 'inner', [Symbol.unscopables]: { keys: true } }; with (o) { return keys; } });
T('unscopables false does not hide', () => { var keys = 'outer'; const o = { keys: 'inner', [Symbol.unscopables]: { keys: false } }; with (o) { return keys; } });
T('Array.prototype unscopables', () => { var values = 'outer'; with ([]) { return values; } });
T('increment through it', () => { const o = { a: 1 }; with (o) { a++; a += 2; } return o.a; });
T('the body sees outer vars', () => { var z = 'zz'; const o = {}; with (o) { return z; } });
T('var in the body is hoisted out', () => { const o = {}; with (o) { var q = 4; } return q + ',' + ('q' in o); });

// `this` across every call form: methods, extraction, call/apply/bind, arrows,
// callbacks, classes, accessors and primitive receivers.
//
// .mjs on purpose. tsmc runs strict, so an unbound `this` is undefined and a
// primitive receiver is not boxed; node only agrees when it treats the file as
// a module. As CommonJS node would report globalThis here, and eleven of these
// cases would differ for that reason alone.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}
// Modules are strict, so an unbound `this` is undefined rather than globalThis.
function who() { return this === undefined ? 'undefined' : (this === globalThis ? 'global' : typeof this); }

// --- call forms ---
T('method-call', () => { const o = { tag: 'o', m() { return this.tag; } }; return o.m(); });
T('extracted-method', () => { const o = { tag: 'o', m() { return this === undefined ? 'undefined' : 'bound'; } }; const f = o.m; return f(); });
T('bare-function', () => who());
T('nested-function-in-method', () => { const o = { m() { function inner() { return this === undefined; } return inner(); } }; return o.m(); });
T('arrow-in-method', () => { const o = { tag: 'o', m() { return (() => this.tag)(); } }; return o.m(); });
T('arrow-at-top-level', () => (() => this === undefined || this === globalThis)());
T('call-explicit', () => { function f() { return this.tag; } return f.call({ tag: 'c' }); });
T('apply-explicit', () => { function f(a) { return this.tag + a; } return f.apply({ tag: 'a' }, ['!']); });
T('bind-explicit', () => { function f() { return this.tag; } return f.bind({ tag: 'b' })(); });
T('bind-then-call-ignored', () => { function f() { return this.tag; } return f.bind({ tag: 'b' }).call({ tag: 'other' }); });
T('bind-twice', () => { function f() { return this.tag; } return f.bind({ tag: '1' }).bind({ tag: '2' })(); });
T('bind-partial-args', () => { function f(a, b) { return a + b; } return f.bind(null, 1)(2); });
T('bind-length', () => { function f(a, b, c) {} return f.bind(null, 1).length; });
T('bind-name', () => { function f() {} return f.bind(null).name; });
T('call-null-strict', () => { function f() { return this === null; } return f.call(null); });
T('call-primitive-strict', () => { function f() { return typeof this; } return f.call(5); });
T('call-undefined', () => { function f() { return this === undefined; } return f.call(undefined); });

// --- indirect and computed calls ---
T('computed-member-call', () => { const o = { tag: 'o', m() { return this.tag; } }; return o['m'](); });
T('chained-call', () => { const o = { inner: { tag: 'i', m() { return this.tag; } } }; return o.inner.m(); });
T('parenthesised-call', () => { const o = { tag: 'o', m() { return this.tag; } }; return (o.m)(); });
T('comma-drops-receiver', () => { const o = { tag: 'o', m() { return this === undefined; } }; return (0, o.m)(); });
T('optional-call-keeps-receiver', () => { const o = { tag: 'o', m() { return this.tag; } }; return o?.m(); });
T('array-element-call', () => { const a = [function () { return this === a; }]; return a[0](); });
T('iife-this', () => (function () { return this === undefined; })());
T('call-via-reflect', () => { function f() { return this.tag; } return Reflect.apply(f, { tag: 'r' }, []); });

// --- callbacks ---
T('foreach-thisarg', () => { const out = []; [1].forEach(function () { out.push(this.tag); }, { tag: 'ta' }); return out; });
T('map-thisarg', () => [1].map(function () { return this.tag; }, { tag: 'm' }));
T('foreach-no-thisarg', () => { const out = []; [1].forEach(function () { out.push(this === undefined); }); return out; });
T('sort-comparator-this', () => { let seen; [2, 1].sort(function () { seen = this === undefined; return 0; }); return seen; });
T('arrow-callback-keeps-outer', () => { const o = { tag: 'o', run() { return [1].map(() => this.tag); } }; return o.run(); });

// --- classes ---
T('class-method-this', () => { class C { constructor() { this.tag = 'c'; } m() { return this.tag; } } return new C().m(); });
T('class-extracted-method', () => { class C { m() { return this === undefined; } } const f = new C().m; return f(); });
T('class-static-this', () => { class C { static m() { return this === C; } } return C.m(); });
T('class-getter-this', () => { class C { constructor() { this.v = 1; } get g() { return this.v; } } return new C().g; });
T('class-field-arrow-this', () => { class C { tag = 'f'; get = () => this.tag; } const f = new C().get; return f(); });
T('class-ctor-this-is-instance', () => { class C { constructor() { this.self = this; } } const c = new C(); return c.self === c; });
T('subclass-method-this', () => { class A { m() { return this.tag; } } class B extends A { constructor() { super(); this.tag = 'b'; } } return new B().m(); });

// --- getters/setters and receivers ---
T('getter-receiver-is-object', () => { const o = { tag: 'o', get g() { return this.tag; } }; return o.g; });
T('getter-through-proto', () => { const proto = { get g() { return this.tag; } }; const o = Object.create(proto); o.tag = 'child'; return o.g; });
T('setter-receiver', () => { let seen; const proto = { set s(v) { seen = this.tag; } }; const o = Object.create(proto); o.tag = 'child'; o.s = 1; return seen; });
T('destructured-getter-loses-this', () => { const o = { tag: 'o', get g() { return this === o; } }; const { g } = o; return g; });

// --- primitives and boxing ---
T('string-method-this', () => 'abc'.charAt(1));
T('number-tostring-this', () => (255).toString(16));
T('call-on-primitive-receiver', () => { return Object.prototype.toString.call('s'); });
T('generic-array-method', () => Array.prototype.join.call({ 0: 'a', 1: 'b', length: 2 }, '-'));
T('generic-with-primitive', () => Array.prototype.map.call('ab', (c) => c.toUpperCase()).join(''));

// --- this in odd positions ---
T('this-in-getter-of-class-static', () => { class C { static get g() { return this === C; } } return C.g; });
T('this-in-object-shorthand', () => { const o = { tag: 'o', m: function () { return this.tag; } }; return o.m(); });
T('this-after-detach-reattach', () => { const a = { tag: 'a', m() { return this.tag; } }; const b = { tag: 'b' }; b.m = a.m; return b.m(); });
T('this-in-nested-arrow-chain', () => { const o = { tag: 'o', m() { return (() => (() => this.tag)())(); } }; return o.m(); });

console.log(rows.join('\n'));

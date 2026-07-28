// Class members: field initialisation order and `this` within it, private
// members, super, construction rules, and subclassing builtins. Method vs
// field is syntax — `m() {}` is a prototype method, `m = () => {}` is an own
// field whose arrow closes over the instance.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// --- field initialisation order ---
T('field-order', () => { const o = []; class C { a = o.push('a'); b = o.push('b'); constructor() { o.push('ctor'); } } new C(); return o; });
T('field-before-ctor-body', () => { class C { x = 1; constructor() { this.y = this.x + 1; } } return new C().y; });
T('field-this', () => { class C { a = 1; b = this.a + 1; } return new C().b; });
T('field-derived-after-super', () => { const o = []; class A { constructor() { o.push('A'); } } class B extends A { f = o.push('field'); constructor() { super(); o.push('after-super'); } } new B(); return o; });
T('field-derived-sees-base', () => { class A { constructor() { this.base = 1; } } class B extends A { f = this.base + 1; } return new B().f; });
T('field-arrow-this', () => { class C { v = 5; get = () => this.v; } const c = new C(); const g = c.get; return g(); });
T('field-own-not-proto', () => { class C { x = 1; } return [Object.hasOwn(new C(), 'x'), Object.hasOwn(C.prototype, 'x')]; });
T('field-shadows-proto-method', () => { class C { m() { return 'proto'; } } class D extends C { m = () => 'field'; } return new D().m(); });
T('field-undefined-default', () => { class C { x; } const c = new C(); return [Object.hasOwn(c, 'x'), c.x]; });
T('static-field-order', () => { const o = []; class C { static a = o.push('a'); static b = o.push('b'); } return o; });
T('static-field-this', () => { class C { static a = 1; static b = this.a + 1; } return C.b; });

// --- private members ---
T('private-field', () => { class C { #x = 1; get() { return this.#x; } } return new C().get(); });
T('private-not-enumerable', () => { class C { #x = 1; } return Object.keys(new C()).length; });
T('private-not-in-json', () => { class C { #x = 1; y = 2; } return JSON.stringify(new C()); });
T('private-method', () => { class C { #m() { return 'priv'; } call() { return this.#m(); } } return new C().call(); });
T('private-getter', () => { class C { get #v() { return 7; } read() { return this.#v; } } return new C().read(); });
T('private-static', () => { class C { static #n = 3; static get() { return C.#n; } } return C.get(); });
T('private-static-method', () => { class C { static #m() { return 'sp'; } static call() { return C.#m(); } } return C.call(); });
T('private-brand-check', () => { class C { #x = 1; static has(o) { return #x in o; } } return [C.has(new C()), C.has({})]; });
T('private-cross-instance', () => { class C { #x = 1; peek(o) { return o.#x; } } return new C().peek(new C()); });
T('private-inherited-access', () => { class A { #x = 1; get() { return this.#x; } } class B extends A {} return new B().get(); });
T('private-getOwnPropertyNames', () => { class C { #x = 1; y = 2; } return Object.getOwnPropertyNames(new C()); });

// --- super ---
T('super-method', () => { class A { m() { return 'A'; } } class B extends A { m() { return super.m() + 'B'; } } return new B().m(); });
T('super-getter', () => { class A { get v() { return 1; } } class B extends A { get v() { return super.v + 1; } } return new B().v; });
T('super-arrow-inherits', () => { class A { m() { return 'A'; } } class B extends A { m() { const f = () => super.m(); return f(); } } return new B().m(); });
T('super-implicit-ctor-args', () => { class A { constructor(a, b) { this.sum = a + b; } } class B extends A {} return new B(2, 3).sum; });

// --- new.target and construction ---
T('new-target-ctor', () => { class C { constructor() { this.n = new.target.name; } } return new C().n; });
T('new-target-subclass', () => { class A { constructor() { this.n = new.target.name; } } class B extends A {} return new B().n; });
T('new-target-plain-call', () => { function f() { return new.target === undefined; } return f(); });
T('class-call-without-new', () => { class C {} return C(); });
T('class-typeof', () => { class C {} return typeof C; });
T('class-name', () => { class C {} return C.name; });
T('class-proto-ctor-backref', () => { class C {} return C.prototype.constructor === C; });
T('class-proto-not-enumerable', () => { class C { m() {} } return Object.keys(C.prototype).length; });
T('class-methods-not-ctor', () => { class C { m() {} } try { new (new C()).m(); return 'constructed'; } catch (e) { return 'THROW:' + e.constructor.name; } });

// --- subclassing builtins ---
T('extend-array-length', () => { class A extends Array {} const a = new A(); a.push(1, 2); return [a.length, Array.isArray(a)]; });
T('extend-array-instanceof', () => { class A extends Array {} const a = new A(); return [a instanceof A, a instanceof Array]; });
T('extend-array-json', () => { class A extends Array {} const a = new A(); a.push(1); return JSON.stringify(a); });
T('extend-error-message', () => { class E extends Error {} return new E('boom').message; });
T('extend-error-name', () => { class E extends Error {} return new E('x').name; });
T('extend-error-instanceof', () => { class E extends Error {} const e = new E('x'); return [e instanceof E, e instanceof Error]; });
T('extend-error-tostring', () => { class E extends Error { constructor(m) { super(m); this.name = 'E'; } } return String(new E('boom')); });
T('extend-error-stack', () => { class E extends Error {} return typeof new E('x').stack; });
T('extend-map', () => { class M extends Map {} const m = new M(); m.set('a', 1); return [m.get('a'), m.size, m instanceof Map]; });
T('extend-set-method', () => { class S extends Set { sum() { let n = 0; for (const v of this) n += v; return n; } } return new S([1, 2, 3]).sum(); });
T('extend-promise', () => { class P extends Promise {} return typeof P.resolve(1).then; });

// --- accessors and inheritance ---
T('accessor-inherited', () => { class A { get v() { return 1; } } class B extends A {} return new B().v; });
T('accessor-setter-only', () => { class C { set v(x) { this._v = x; } } const c = new C(); c.v = 3; return [c._v, c.v]; });
T('accessor-on-proto', () => { class C { get v() { return 1; } } const d = Object.getOwnPropertyDescriptor(C.prototype, 'v'); return [typeof d.get, d.enumerable, d.configurable]; });
T('accessor-override-with-field', () => { class A { get v() { return 'proto'; } } class B extends A { } const b = new B(); try { b.v = 'own'; } catch (e) { return 'THROW:' + e.constructor.name; } return b.v; });
T('static-inherited', () => { class A { static m() { return 'sA'; } } class B extends A {} return B.m(); });
T('static-proto-chain', () => { class A {} class B extends A {} return Object.getPrototypeOf(B) === A; });

console.log(rows.join('\n'));

// Not asserted, all still divergent:
//   - a computed field key is re-evaluated per instance, not once when the
//     class is defined;
//   - reading a private field off an object without that brand yields
//     undefined instead of throwing a TypeError;
//   - `super.m()` inside a *static* method throws, and `super.x = 5` and
//     `super.m()` inside an object-literal method do not compile at all;
//   - a derived constructor may use `this` before super(), or never call
//     super() at all, without the ReferenceError those owe;
//   - an object returned from a base constructor does not become the derived
//     `this`;
//   - `class C extends null {}` throws rather than giving a null prototype;
//   - Function.prototype.toString does not return source text.

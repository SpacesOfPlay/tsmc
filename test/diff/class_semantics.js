// Dense coverage of class semantics: field and constructor ordering, private
// members, inheritance, and what ends up enumerable.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

T('field-order', () => { const log = []; class C { a = log.push('a'); b = log.push('b'); } new C(); return log; });
T('field-this', () => { class C { a = 1; b = this.a + 1; } return new C().b; });
T('field-arrow-this', () => { class C { v = 7; get = () => this.v; } return new C().get(); });
T('static-this', () => { class C { static v = 1; static w = this.v + 1; } return C.w; });
T('subclass-ctor-order', () => {
  const log = [];
  class A { constructor() { log.push('A'); } }
  class B extends A { f = log.push('f'); constructor() { super(); log.push('B'); } }
  new B();
  return log;
});
T('private-method', () => { class C { #m() { return 1; } run() { return this.#m(); } } return new C().run(); });
T('private-field', () => { class C { #v = 5; get() { return this.#v; } } return new C().get(); });
T('private-static', () => { class C { static #v = 1; static get() { return C.#v; } } return C.get(); });
T('private-getter', () => { class C { #v = 1; get #g() { return this.#v; } run() { return this.#g; } } return new C().run(); });
T('private-setter', () => { class C { #v = 0; set #s(n) { this.#v = n; } run() { this.#s = 4; return this.#v; } } return new C().run(); });
T('private-brand', () => { class C { #v = 1; static has(o) { return #v in o; } } return [C.has(new C()), C.has({})]; });
T('private-not-enumerable', () => { class C { #v = 1; pub = 2; } return Object.keys(new C()); });
T('accessor-inherit', () => { class A { get v() { return 1; } } class B extends A { } return new B().v; });
T('accessor-override-super', () => { class A { get v() { return 1; } } class B extends A { get v() { return super.v + 1; } } return new B().v; });
T('method-super', () => { class A { m() { return 'A'; } } class B extends A { m() { return 'B' + super.m(); } } return new B().m(); });
T('static-inherit', () => { class A { static s() { return 1; } } class B extends A { } return B.s(); });
T('ctor-return-object', () => { class C { constructor() { return { custom: 1 }; } } return new C().custom; });
T('derived-return-object', () => { class A { } class B extends A { constructor() { super(); return { custom: 2 }; } } return new B().custom; });
T('new-target-direct', () => { function F() { return new.target === F; } return new F(); });
T('new-target-plain', () => { function F() { return new.target; } return F(); });
T('new-target-derived', () => { class A { constructor() { this.n = new.target.name; } } class B extends A { } return new B().n; });
T('class-name', () => { class Foo { } return Foo.name; });
T('anon-class-name', () => { const X = class { }; return X.name; });
T('class-length', () => { class C { constructor(a, b) { } } return C.length; });
T('method-not-enumerable', () => { class C { m() { } } return Object.keys(C.prototype).length; });
T('field-enumerable', () => { class C { f = 1; } return Object.keys(new C()); });
T('static-on-ctor', () => { class C { static m() { return 1; } } return [typeof C.m, Object.keys(C).length]; });
T('extends-expression', () => { const mk = (b) => class extends b { }; class A { m() { return 1; } } return new (mk(A))().m(); });
T('instanceof-chain', () => { class A { } class B extends A { } const b = new B(); return [b instanceof B, b instanceof A, b instanceof Object]; });
T('getter-setter-pair', () => { class C { #v = 0; get v() { return this.#v; } set v(n) { this.#v = n * 2; } } const c = new C(); c.v = 3; return c.v; });
T('class-in-expression', () => (class { static x = 5; }).x);
T('accessor-not-own', () => { class C { get v() { return 1; } } const c = new C(); return [Object.keys(c).length, c.v]; });
T('prototype-constructor', () => { class C { } return [C.prototype.constructor === C, new C().constructor === C]; });
T('computed-method', () => { const k = 'm'; class C { [k]() { return 3; } } return new C().m(); });
T('computed-accessor', () => { const k = 'v'; class C { get [k]() { return 4; } } return new C().v; });
T('static-block-sees-class', () => { class C { static x; static { C.x = 5; } } return C.x; });
T('field-init-order-vs-ctor', () => {
  const log = [];
  class C { f = log.push('field'); constructor() { log.push('ctor'); } }
  new C();
  return log;
});
T('super-property-read', () => { class A { constructor() { this.x = 1; } } class B extends A { m() { return super.constructor === A; } } return new B().m(); });
T('tostring-type', () => { class C { } return typeof C.toString(); });

console.log(rows.join('\n'));

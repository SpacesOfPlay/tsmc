// A computed key does not change what a class member is. A method stays
// non-enumerable whether it was written `m() {}` or `[k]() {}`, a field
// stays enumerable either way, and an object literal is the other way
// around: its methods are enumerable, computed or not.

const T = (l, f) => {
  try { console.log(l + ' = ' + f()); }
  catch (e) { console.log(l + ' = ' + e.name + ': ' + e.message); }
};

const d = (o, k) => {
  const x = Object.getOwnPropertyDescriptor(o, k);
  if (x === undefined) return 'none';
  const kind = 'get' in x || 'set' in x ? 'accessor' : 'value';
  return kind + (x.writable === undefined ? '' : ' w=' + x.writable) +
    ' e=' + x.enumerable + ' c=' + x.configurable;
};

const k = 'm';
const sym = Symbol('s');

class A {
  [k]() { return 'proto'; }
  static [k]() { return 'static'; }
  *[k + 'g']() { yield 1; }
  async [k + 'a']() { return 1; }
  async *[k + 'ag']() { yield 1; }
  static async *[k + 'sag']() { yield 1; }
  get [k + 'get']() { return 'g'; }
  set [k + 'set'](v) { this._v = v; }
  [sym]() { return 'sym'; }
  [k + 'f'] = 1;
  static [k + 'sf'] = 2;
}

T('method', () => d(A.prototype, k));
T('static-method', () => d(A, k));
T('generator', () => d(A.prototype, k + 'g'));
T('async', () => d(A.prototype, k + 'a'));
T('async-generator', () => d(A.prototype, k + 'ag'));
T('static-async-generator', () => d(A, k + 'sag'));
T('getter', () => d(A.prototype, k + 'get'));
T('setter', () => d(A.prototype, k + 'set'));
T('symbol-method', () => d(A.prototype, sym));
T('instance-field', () => d(new A(), k + 'f'));
T('static-field', () => d(A, k + 'sf'));

T('proto-keys', () => JSON.stringify(Object.keys(A.prototype)));
T('ctor-keys', () => JSON.stringify(Object.keys(A)));
T('instance-keys', () => JSON.stringify(Object.keys(new A())));
T('proto-own-names', () => JSON.stringify(Object.getOwnPropertyNames(A.prototype).sort()));
T('proto-own-symbols', () => Object.getOwnPropertySymbols(A.prototype).length);
T('for-in-instance', () => { const a = []; for (const p in new A()) a.push(p); return JSON.stringify(a); });
T('json-instance', () => JSON.stringify(new A()));

T('call-method', () => new A()[k]());
T('call-static', () => A[k]());
T('call-symbol', () => new A()[sym]());
T('call-getter', () => new A()[k + 'get']);
T('call-setter', () => { const a = new A(); a[k + 'set'] = 9; return a._v; });
T('call-generator', () => [...new A()[k + 'g']()].join());

// the same names written literally, for comparison
class B {
  m() { return 'proto'; }
  static m() { return 'static'; }
  get g() { return 1; }
}
T('literal-method', () => d(B.prototype, 'm'));
T('literal-static', () => d(B, 'm'));
T('literal-getter', () => d(B.prototype, 'g'));

// object literals keep their members enumerable
const o = { [k]() { return 1; }, [k + '2']: 2, get [k + '3']() { return 3; }, m4() { return 4; } };
T('object-computed-method', () => d(o, k));
T('object-computed-value', () => d(o, k + '2'));
T('object-computed-getter', () => d(o, k + '3'));
T('object-plain-method', () => d(o, 'm4'));
T('object-keys', () => JSON.stringify(Object.keys(o)));

// a computed key is evaluated once, in source order, and coerced to a
// property key the usual way
const seen = [];
const key = (name) => ({ toString() { seen.push(name); return name; } });
class C {
  [key('one')]() {}
  [key('two')]() {}
  static [key('three')]() {}
}
T('key-eval-order', () => JSON.stringify(seen));
T('key-coerced', () => JSON.stringify(Object.getOwnPropertyNames(C.prototype).sort()));

class D { [1 + 1]() { return 'two'; } }
T('numeric-key', () => new D()[2]() + ' ' + d(D.prototype, '2'));

// a later member with the same computed name replaces the earlier one
class E { [k]() { return 'first'; } [k]() { return 'second'; } }
T('duplicate-key', () => new E()[k]() + ' ' + d(E.prototype, k));

// subclassing sees the same shape
class F extends A { [k + 'x']() { return 'sub'; } }
T('subclass-method', () => d(F.prototype, k + 'x'));
T('subclass-inherited', () => new F()[k]());
T('subclass-keys', () => JSON.stringify(Object.keys(F.prototype)));

// the member is writable and configurable, so it can be redefined or deleted
T('redefine', () => { const p = A.prototype; const old = p[k]; Object.defineProperty(p, k, { value: () => 'new' }); const v = new A()[k](); p[k] = old; return v; });
T('delete', () => { class G { [k]() {} } return delete G.prototype[k]; });

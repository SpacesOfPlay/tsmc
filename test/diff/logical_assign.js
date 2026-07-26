// Logical assignment (||=, &&=, ??=) to members and computed properties.
// The store only happens on the branch that takes it, so a setter is left
// alone when the operator short-circuits, and the target's subexpressions
// are evaluated exactly once.

const out = [];
const r = (label, v) => out.push(label + '=' + JSON.stringify(v));

// Member targets, both branches of each operator.
{ const x = { v: 0 }; x.v ||= 5; r('member-or', x.v); }
{ const x = { v: 2 }; x.v ||= 9; r('member-or-skip', x.v); }
{ const x = { v: 1 }; x.v &&= 5; r('member-and', x.v); }
{ const x = { v: 0 }; x.v &&= 9; r('member-and-skip', x.v); }
{ const x = {}; x.v ??= 5; r('member-nullish', x.v); }
{ const x = { v: 0 }; x.v ??= 9; r('member-nullish-skip', x.v); }

// Computed targets.
{ const a = [0]; a[0] ||= 5; r('index-or', a[0]); }
{ const a = [1]; a[0] &&= 5; r('index-and', a[0]); }
{ const a = [undefined]; a[0] ??= 5; r('index-nullish', a[0]); }
{ const x = { k: 0 }; x['k'] ||= 7; r('index-string-key', x.k); }
{ const x = {}; x[0] ??= 1; r('numeric-key', JSON.stringify(x)); }
{ const a = []; a[3] ??= 7; r('sparse', JSON.stringify(a)); }

// The expression's value.
{ const x = { v: 0 }; r('value-when-assigned', (x.v ||= 5)); }
{ const x = { v: 3 }; r('value-when-skipped', (x.v ||= 5)); }

// A setter must not run when the operator short-circuits.
{
  let sets = 0;
  const x = { _v: 1, get v() { return this._v; }, set v(n) { sets++; this._v = n; } };
  x.v ||= 9;
  r('setter-not-run', sets);
}
{
  let sets = 0;
  const x = { _v: 0, get v() { return this._v; }, set v(n) { sets++; this._v = n; } };
  x.v ||= 9;
  r('setter-run', sets + ',' + x._v);
}
{
  let sets = 0;
  const x = { _v: null, get v() { return this._v; }, set v(n) { sets++; this._v = n; } };
  x.v ??= 9;
  r('setter-run-nullish', sets + ',' + x._v);
}
// The getter is read once, not once per branch.
{
  let reads = 0;
  const x = { get v() { reads++; return 0; }, set v(q) {} };
  x.v ||= 1;
  r('getter-once', reads);
}

// The right-hand side is only evaluated on the assigning branch.
{ let ev = 0; const f = () => { ev++; return 9; }; const x = { v: 1 }; x.v ||= f(); r('rhs-not-run', ev); }
{ let ev = 0; const f = () => { ev++; return 9; }; const x = { v: 0 }; x.v ||= f(); r('rhs-run', ev); }

// The object and key expressions are evaluated exactly once, on both branches.
{ let n = 0; const box = { o: { v: 0 } }; const get = () => { n++; return box.o; }; get().v ||= 5; r('object-once', n); }
{ let n = 0; const a = [0]; const k = () => { n++; return 0; }; a[k()] ||= 5; r('key-once-assigned', n + ',' + a[0]); }
{ let n = 0; const a = [1]; const k = () => { n++; return 0; }; a[k()] ||= 5; r('key-once-skipped', n + ',' + a[0]); }

// Private fields.
{ class C { #v = 0; run() { this.#v ||= 5; return this.#v; } } r('private', new C().run()); }
{ class C { #v = 7; run() { this.#v ||= 5; return this.#v; } } r('private-skip', new C().run()); }

// Nesting and chaining.
{ const x = { a: { b: 0 } }; x.a.b ??= 4; r('nested', x.a.b); }
{ const x = { a: 0, b: 0 }; x.a ||= (x.b ||= 2); r('chained', x.a + ',' + x.b); }
{ const m = { data: {} }; m.data['x'] ??= []; m.data['x'].push(1); r('lazy-init', JSON.stringify(m.data)); }

// Identifier targets are unchanged, and only they take the binding's name.
{ let a = 0; a ||= 5; r('ident', a); }
{ let a; a ??= function () {}; r('ident-named', a.name); }
{ const x = {}; x.v ??= function () {}; r('member-not-named', x.v.name); }

console.log(out.join('\n'));

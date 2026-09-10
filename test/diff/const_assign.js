// A store to an immutable binding is a runtime TypeError, not a refusal to
// run the program: the right-hand side is evaluated first, everything
// before the store has already happened, and a catch resumes normally.

const t = (label, f) => {
  try { console.log(label, '->', String(f())); }
  catch (e) { console.log(label, 'threw', e.constructor.name, e.message); }
};

const c = 1;
t('c = 2', () => { c = 2; });
t('c after', () => c);
t('c += 1', () => { c += 1; });
t('c++', () => { c++; });
t('++c', () => { ++c; });
t('c **= 2', () => { c **= 2; });
t('c ||= 9', () => { c ||= 9; });
t('c &&= 9', () => { c &&= 9; });
t('c ??= 9', () => { c ??= 9; });

// the value is computed before the store, so its effects stand
let ran = 0;
t('c = side()', () => { c = (ran++, 5); });
t('side ran', () => ran);

// short-circuit assignment does not reach the store when it does not have to
const truthy = 1, nul = null;
t('truthy ||= 9', () => { truthy ||= 9; });
t('nul ??= 9 (nul is null)', () => { nul ??= 9; });

// destructuring onto a const
t('[c] = [3]', () => { [c] = [3]; });
t('({x: c} = {x: 4})', () => { ({ x: c } = { x: 4 }); });
t('[c = 7] = []', () => { [c = 7] = []; });

// a const in an enclosing function, reached as an upvalue
t('upvalue const', () => { const u = 1; return (() => { u = 2; })(); });
t('upvalue read after', () => { const u = 1; try { (() => { u = 2; })(); } catch (e) { return u; } });

// loop heads
t('for-of const', () => { for (const v of [1]) { v = 2; } });
t('for-in const', () => { for (const k in { a: 1 }) { k = 'b'; } });
t('for(const;;)', () => { for (const i = 0; i < 1; ) { i++; } });

// a class name is immutable inside its own body, and mutable outside it
t('class expr name', () => { const C = class D { m() { D = 1; } }; return new C().m(); });
t('class decl name inside', () => { class E { m() { E = 1; } } return new E().m(); });
t('class decl name outside', () => { class F { } F = 1; return typeof F; });

// bindings that only look immutable
t('let', () => { let l = 1; l = 2; return l; });
t('catch param', () => { try { throw 1; } catch (e) { e = 2; return e; } });
t('parameter', () => ((p) => { p = 2; return p; })(1));
t('function decl', () => { function g() {} g = 1; return typeof g; });

// the throw is a value, not a parse failure: the code below still runs
console.log('reached the end');

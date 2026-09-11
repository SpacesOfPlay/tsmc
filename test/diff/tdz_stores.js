// A store into a binding that has not been initialized is a ReferenceError,
// as a read of one is. The dead zone is checked before the const rule, so an
// uninitialized const says ReferenceError rather than TypeError.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

T('a plain store', () => { try { a1 = 1; return 'stored'; } catch (e) { return e.constructor.name; } });
T('through an array pattern', () => { try { [a2] = [1]; return 'stored'; } catch (e) { return e.constructor.name; } });
T('through an object pattern', () => { try { ({ p: a3 } = { p: 1 }); return 'stored'; } catch (e) { return e.constructor.name; } });
T('with a rest element', () => { try { [...a4] = [1]; return 'stored'; } catch (e) { return e.constructor.name; } });
T('compound', () => { try { a5 += 1; return 'stored'; } catch (e) { return e.constructor.name; } });
T('postfix', () => { try { a6++; return 'stored'; } catch (e) { return e.constructor.name; } });
T('logical', () => { try { a7 ||= 1; return 'stored'; } catch (e) { return e.constructor.name; } });
T('a const in its dead zone', () => { try { c1 = 1; return 'stored'; } catch (e) { return e.constructor.name; } });
T('a class in its dead zone', () => { try { K = 1; return 'stored'; } catch (e) { return e.constructor.name; } });
T('from a closure', () => {
  const f = () => { try { a8 = 1; return 'stored'; } catch (e) { return e.constructor.name; } };
  return f();
});
T('a read, for comparison', () => { try { return a9; } catch (e) { return e.constructor.name; } });

let a1, a2, a3, a4, a5, a6, a7, a8, a9;
const c1 = 0;
class K {}

// after the declaration the store lands
T('after the declaration', () => { let v = 0; v = 5; return v; });
T('a const after it still refuses, as a const', () => { const k = 1; try { k = 2; return 'stored'; } catch (e) { return e.constructor.name; } });

// a block re-holes its bindings, and the switch case a declaration never reaches
T('inside a block', () => { try { { b1 = 1; let b1; } return 'stored'; } catch (e) { return e.constructor.name; } });
T('a switch case before the declaration', () => {
  switch (1) { case 1: try { s1 = 1; return 'stored'; } catch (e) { return e.constructor.name; } case 2: let s1; }
});
T('a switch case the declaration never ran for', () => {
  switch (2) { case 1: let s2 = 1; break; case 2: try { s2 = 2; return 'stored'; } catch (e) { return e.constructor.name; } }
});
T('a loop re-holes each turn', () => {
  const seen = [];
  for (let i = 0; i < 2; i++) {
    try { seen.push(inner); } catch (e) { seen.push(e.constructor.name); }
    let inner = i;
  }
  return seen.join(',');
});
T('a loop body store after the declaration', () => {
  let n = 0;
  for (let i = 0; i < 3; i++) { let v = 0; v = i; n += v; }
  return n;
});
T('a closure made before the declaration', () => {
  let out;
  { const f = () => { try { cy = 1; return 'stored'; } catch (e) { return e.constructor.name; } }; out = f(); let cy; }
  return out;
});
T('a closure made after it', () => {
  let out;
  { let cz = 1; const f = () => { cz = 2; return cz; }; out = f(); }
  return out;
});
T('a var is not in a dead zone', () => { vv = 3; return vv; });
var vv;

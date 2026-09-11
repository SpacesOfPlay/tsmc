// A write or a delete the object refuses is a TypeError in strict-mode code
// and nothing at all in sloppy code: the assignment still evaluates to its
// right-hand side, and `delete` answers false.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

const ro = () => { const o = {}; Object.defineProperty(o, 'p', { value: 1 }); return o; };
const getterOnly = () => ({ get g() { return 1; } });

// --- sloppy: dropped -------------------------------------------------------
T('write', () => { const o = ro(); o.p = 2; return o.p; });
T('the value of the assignment', () => { const o = ro(); return (o.p = 7); });
T('through an index', () => { const o = ro(); o['p'] = 2; return o.p; });
T('compound', () => { const o = ro(); o.p += 1; return o.p; });
T('postfix', () => { const o = ro(); return [o.p++, o.p].join(','); });
T('prefix', () => { const o = ro(); return [++o.p, o.p].join(','); });
T('logical', () => { const o = ro(); o.p ||= 9; o.p &&= 9; return o.p; });
T('frozen', () => { const o = Object.freeze({ a: 1 }); o.a = 2; return o.a; });
T('sealed', () => { const o = Object.seal({ a: 1 }); o.a = 2; o.b = 3; return [o.a, typeof o.b].join(','); });
T('non-extensible', () => { const o = Object.preventExtensions({}); o.a = 1; return typeof o.a; });
T('a getter with no setter', () => { const o = getterOnly(); o.g = 2; return o.g; });
T('an inherited read-only', () => {
  const base = {};
  Object.defineProperty(base, 'p', { value: 1 });
  const o = Object.create(base);
  o.p = 2;
  return [o.p, Object.prototype.hasOwnProperty.call(o, 'p')].join(',');
});
T('a frozen array element', () => { const a = Object.freeze([1]); a[0] = 2; return a[0]; });
T('past the end of a sealed array', () => { const a = Object.seal([1]); a[1] = 2; return [a.length, typeof a[1]].join(','); });
T('a read-only property of a function', () => {
  function f() {}
  Object.defineProperty(f, 'p', { value: 1 });
  f.p = 2;
  return f.p;
});
T("a function's name", () => { function f() {} f.name = 'other'; return f.name; });
T("a class's prototype", () => { class C {} C.prototype = 1; return typeof C.prototype; });
T('a property on a number', () => { const n = 1; n.x = 2; return typeof n.x; });
T('a property on a string', () => { const s = 'ab'; s.x = 2; return [typeof s.x, s.length].join(','); });

T('delete', () => { const o = ro(); return [delete o.p, o.p].join(','); });
T('delete through an index', () => { const o = ro(); return [delete o['p'], o.p].join(','); });
T('delete an absent property', () => { const o = {}; return delete o.nope; });
T('delete from a sealed array', () => { const a = Object.seal([1]); return [delete a[0], a[0]].join(','); });
T('delete a configurable one', () => { const o = { a: 1 }; return [delete o.a, typeof o.a].join(','); });
T('delete a builtin constant', () => delete Math.PI);

// --- strict: a TypeError ---------------------------------------------------
T('strict write', () => { 'use strict'; const o = ro(); o.p = 2; return o.p; });
T('strict index', () => { 'use strict'; const o = ro(); o['p'] = 2; return o.p; });
T('strict compound', () => { 'use strict'; const o = ro(); o.p += 1; return o.p; });
T('strict postfix', () => { 'use strict'; const o = ro(); o.p++; return o.p; });
T('strict frozen', () => { 'use strict'; const o = Object.freeze({ a: 1 }); o.a = 2; return o.a; });
T('strict non-extensible', () => { 'use strict'; const o = Object.preventExtensions({}); o.a = 1; return 'added'; });
T('strict getter-only', () => { 'use strict'; const o = getterOnly(); o.g = 2; return o.g; });
T('strict frozen array', () => { 'use strict'; const a = Object.freeze([1]); a[0] = 2; return a[0]; });
T('strict function property', () => {
  'use strict';
  function f() {}
  Object.defineProperty(f, 'p', { value: 1 });
  f.p = 2;
  return f.p;
});
T('strict number property', () => { 'use strict'; const n = 1; n.x = 2; return 'added'; });
T('strict delete', () => { 'use strict'; const o = ro(); return delete o.p; });
T('strict delete an absent one', () => { 'use strict'; const o = {}; return delete o.nope; });
T('strict delete a configurable one', () => { 'use strict'; const o = { a: 1 }; return delete o.a; });
T('strict delete from a sealed array', () => { 'use strict'; const a = Object.seal([1]); return delete a[0]; });

// a class body is strict whatever surrounds it
T('inside a class', () => {
  class C { static run() { const o = ro(); o.p = 2; return o.p; } }
  return C.run();
});

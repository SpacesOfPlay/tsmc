// A bare name is a binding, not a property. Assigning to one that does not
// exist creates a global in sloppy code and is a ReferenceError in strict
// code; `delete` of a binding answers false, and only a global some
// assignment created can go.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

// --- assigning to a name with no binding -----------------------------------
T('sloppy creates a global', () => { madeBySloppy = 1; return [typeof madeBySloppy, globalThis.madeBySloppy].join(','); });
T('strict refuses', () => { 'use strict'; neverMade = 1; return typeof neverMade; });
T('strict is fine for one that exists', () => { 'use strict'; madeBySloppy = 2; return madeBySloppy; });
T('a declared binding is not a global', () => { let l = 1; l = 2; return [l, typeof globalThis.l].join(','); });

// the three value properties of the global object are read-only
T('undefined, sloppy', () => { undefined = 1; return typeof undefined; });
T('NaN, sloppy', () => { NaN = 1; return typeof NaN; });
T('Infinity, sloppy', () => { Infinity = 1; return typeof Infinity; });
T('undefined, strict', () => { 'use strict'; undefined = 1; return typeof undefined; });
T('NaN, strict', () => { 'use strict'; NaN = 1; return typeof NaN; });
T('the value of the refused assignment', () => { let seen = (undefined = 7); return [seen, typeof undefined].join(','); });

// --- deleting a bare name --------------------------------------------------
T('a local', () => { var v = 1; return [delete v, v].join(','); });
T('a let', () => { let l = 1; return [delete l, l].join(','); });
T('a parameter', () => ((p) => [delete p, p].join(','))(1));
T('a function declaration', () => { function g() {} return [delete g, typeof g].join(','); });
T('a captured binding', () => { let c = 1; return (() => [delete c, c].join(','))(); });
T('a global an assignment made', () => { madeToDelete = 1; return [delete madeToDelete, typeof madeToDelete].join(','); });
T('one that was never there', () => delete nothingOfTheSort);
T('undefined', () => [delete undefined, typeof undefined].join(','));
T('NaN', () => delete NaN);
T('the operand is still a reference', () => { let calls = 0; const f = () => { calls++; return {}; }; return [delete f().x, calls].join(','); });

// --- and the property forms are unchanged ----------------------------------
T('a property of the global object', () => { globalThis.viaGlobalThis = 1; return [delete globalThis.viaGlobalThis, typeof globalThis.viaGlobalThis].join(','); });
T('a builtin binding', () => { const had = typeof Math; return [delete globalThis.nothingHere, had].join(','); });

// A property of the global object is what a bare name resolves to. Most
// globals are plain bindings, but Object.defineProperty can give one its own
// descriptor — an accessor, a read-only value, a non-configurable name — and
// then the descriptor is what answers, through the bare name as much as
// through globalThis.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

const def = (name, desc) => Object.defineProperty(globalThis, name, desc);

// --- a data property with a descriptor -----------------------------------
def('dp', { value: 2, writable: true, enumerable: true, configurable: true });
T('bare read', () => dp);
T('typeof', () => typeof dp);
T('through globalThis', () => globalThis.dp);
T('in', () => 'dp' in globalThis);
T('the descriptor is kept', () => JSON.stringify(Object.getOwnPropertyDescriptor(globalThis, 'dp')));
T('a bare write lands on the property', () => { dp = 5; return JSON.stringify([globalThis.dp, Object.getOwnPropertyDescriptor(globalThis, 'dp').value]); });
T('and keeps its attributes', () => JSON.stringify(Object.getOwnPropertyDescriptor(globalThis, 'dp')));
T('a write through globalThis does too', () => { globalThis.dp = 6; return JSON.stringify([dp, Object.getOwnPropertyDescriptor(globalThis, 'dp').value]); });
T('compound assignment', () => { dp += 1; return dp; });
T('increment', () => { dp++; return dp; });

// --- read-only ------------------------------------------------------------
def('ro', { value: 3, writable: false, configurable: true });
T('a sloppy write is dropped', () => { ro = 9; return ro; });
T('a strict write throws', () => { 'use strict'; ro = 9; return 'assigned'; });
T('and the value stands', () => ro);

// --- an accessor ----------------------------------------------------------
let taken = 0;
def('acc', { get() { return 40 + taken; }, set(v) { taken = v; }, configurable: true });
T('the getter answers a bare read', () => acc);
T('the setter takes a bare write', () => { acc = 2; return [taken, acc].join(','); });
T('and a write through globalThis', () => { globalThis.acc = 3; return taken; });
T('compound assignment runs both', () => { taken = 0; acc += 1; return [taken, acc].join(','); });
T('increment runs both', () => { taken = 0; acc++; return taken; });

def('getonly', { get() { return 5; }, configurable: true });
T('a sloppy write to a getter-only name', () => { getonly = 1; return getonly; });
T('a strict write to one throws', () => { 'use strict'; getonly = 1; return 'assigned'; });

def('throwing', { get() { throw new RangeError('no'); }, configurable: true });
T('a getter that throws', () => throwing);
T('typeof does not swallow it', () => typeof throwing);

// --- delete ---------------------------------------------------------------
def('conf', { value: 1, configurable: true });
def('nonconf', { value: 1, configurable: false });
T('delete a configurable one', () => { const r = delete conf; return [r, 'conf' in globalThis].join(','); });
T('delete a non-configurable one', () => { const r = delete nonconf; return [r, 'nonconf' in globalThis].join(','); });
T('delete through globalThis', () => { def('conf2', { value: 1, configurable: true }); const r = delete globalThis.conf2; return [r, 'conf2' in globalThis].join(','); });
T('delete a name that is not there', () => delete never_defined_at_all);

// --- a plain binding still behaves like one -------------------------------
T('an implicit global', () => { plain = 7; return [plain, globalThis.plain, 'plain' in globalThis].join(' | '); });
T('assigned through globalThis', () => { globalThis.plain2 = 8; return plain2; });
T('deleted again', () => { const r = delete plain; return [r, typeof globalThis.plain].join(','); });

// --- what the global object inherits -------------------------------------
T('a bare inherited name', () => typeof toString);
T('an inherited name is a function', () => typeof hasOwnProperty);
T('an undeclared name', () => undeclared_name_here);
T('typeof an undeclared name', () => typeof undeclared_name_here);
T('a strict write to an undeclared name', () => { 'use strict'; undeclared_strict = 1; return 'assigned'; });

// --- the property can go while it is being read --------------------------
T('a getter that deletes itself, strict write', () => {
  def('vanishing', { configurable: true, get() { delete globalThis.vanishing; return 2; } });
  const out = [];
  try { (function () { 'use strict'; vanishing ^= 3; })(); out.push('no throw'); }
  catch (e) { out.push('threw ' + e.constructor.name); }
  out.push('still there: ' + ('vanishing' in globalThis));
  return out.join(', ');
});
T('the same in sloppy code', () => {
  def('vanishing2', { configurable: true, get() { delete globalThis.vanishing2; return 2; } });
  vanishing2 ^= 3;
  return [vanishing2, 'vanishing2' in globalThis].join(',');
});

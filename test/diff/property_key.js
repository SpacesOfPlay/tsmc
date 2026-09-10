// ToPropertyKey: an object used as a key is asked for a primitive first,
// and that primitive may be a Symbol, which stays a Symbol rather than
// being turned into a string. Everything else becomes a string.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

const s = Symbol('s');
const boom = () => { throw new Error('should not be reached'); };
const toPrim = { [Symbol.toPrimitive]: () => s, toString: boom, valueOf: boom };
const viaToString = { toString: () => 'ts', valueOf: boom };
const viaValueOf = { toString: null, valueOf: () => 'vo' };

T('read through toPrimitive', () => { const o = { [s]: 'hit' }; return o[toPrim]; });
T('write through toPrimitive', () => { const o = {}; o[toPrim] = 'w'; return o[s]; });
T('literal key', () => { const o = { [toPrim]: 'l' }; return o[s]; });
T('symbol count', () => Object.getOwnPropertySymbols({ [toPrim]: 1 }).length);
T('delete', () => { const o = { [s]: 1 }; delete o[toPrim]; return s in o; });
T('in', () => { const o = { [s]: 1 }; return toPrim in o; });

T('string hint wins', () => { const o = { ts: 1 }; return o[viaToString]; });
T('valueOf when toString is not callable', () => { const o = { vo: 1 }; return o[viaValueOf]; });
T('array index', () => { const a = [7, 8]; return a[{ toString: () => '1' }]; });
T('number key', () => { const o = { 1: 'one' }; return o[{ valueOf: () => 1, toString: null }]; });

// a present but uncallable Symbol.toPrimitive is an error, not a fallback
T('toPrimitive not callable', () => { const o = {}; return o[{ [Symbol.toPrimitive]: 1 }]; });
T('toPrimitive null falls back', () => { const o = { ok: 1 }; return o[{ [Symbol.toPrimitive]: null, toString: () => 'ok' }]; });
T('no primitive at all', () => { const o = {}; return o[{ toString: null, valueOf: null }]; });

// reflection takes the same route
T('defineProperty', () => {
  const o = {};
  Object.defineProperty(o, toPrim, { value: 'd', configurable: true });
  return o[s];
});
T('getOwnPropertyDescriptor', () => Object.getOwnPropertyDescriptor({ [s]: 'g' }, toPrim).value);
T('hasOwnProperty', () => ({ [s]: 1 }).hasOwnProperty(toPrim));
T('Reflect.get', () => Reflect.get({ [s]: 'r' }, toPrim));
T('Reflect.has', () => Reflect.has({ [s]: 1 }, toPrim));

// and so do the keyed collections that are not keyed by property at all
T('Map is not ToPropertyKey', () => { const m = new Map(); m.set(toPrim, 1); return m.get(toPrim); });

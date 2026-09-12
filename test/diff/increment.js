// ++ and -- on a name, in the position where the value is thrown away and in
// the position where it is not. A step in statement position on a plain local
// compiles to one opcode, so everything the long form does has to still hold:
// ToNumeric on a string or an object, a BigInt staying a BigInt, the overflow
// out of the integer range, the TDZ of a lexical binding, a const refusing the
// store, a captured binding, and a `with` object answering for the name.

const T = (l, f) => { try { console.log(l, '->', JSON.stringify(f())); } catch (e) { console.log(l, 'threw', e.constructor.name); } };
T('let in a loop', () => { let s = 0; for (let i = 0; i < 5; i++) s += i; return s; });
T('var in a loop', () => { let s = 0; for (var j = 0; j < 5; j++) s += j; return s; });
T('statement ++', () => { let x = 1; x++; x++; return x; });
T('statement --', () => { let x = 5; x--; return x; });
T('prefix statement', () => { let x = 1; ++x; return x; });
T('value still works', () => { let x = 1; const a = x++; const b = ++x; return [a, b, x]; });
T('string coerces', () => { let x = '5'; x++; return [x, typeof x]; });
T('bigint stays bigint', () => { let x = 5n; x++; return [String(x), typeof x]; });
T('object valueOf', () => { let calls = 0; let x = { valueOf() { calls++; return 7; } }; x++; return [x, calls]; });
T('valueOf that throws', () => { let x = { valueOf() { throw new RangeError('no'); } }; x++; return 'no throw'; });
T('undefined becomes NaN', () => { let x; x++; return [x, Number.isNaN(x)]; });
T('overflow to double', () => { let x = 2147483647; x++; return [x, x === 2147483648]; });
T('underflow', () => { let x = -2147483648; x--; return x; });
T('TDZ', () => { { x++; let x = 1; } return 'no throw'; });
T('const refuses', () => { const c = 1; c++; return 'no throw'; });
T('closure capture', () => { const fs = []; for (let i = 0; i < 3; i++) fs.push(() => i); return fs.map(f => f()).join(','); });
T('captured var incremented', () => { let n = 0; const f = () => { n++; }; f(); f(); return n; });
T('with shadows it', () => { const o = { k: 10 }; let k = 1; with (o) { k++; } return [o.k, k]; });
T('a global', () => { globalThis.gcount = 1; gcount++; return globalThis.gcount; });
T('a parameter', () => { const f = (p) => { p++; return p; }; return f(4); });
T('in a while', () => { let i = 0; let s = 0; while (i < 4) { i++; s += i; } return [i, s]; });
T('nested loops', () => { let s = 0; for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) s += i * j; return s; });
T('float local', () => { let x = 1.5; x++; return x; });
T('NaN local', () => { let x = NaN; x++; return Number.isNaN(x); });

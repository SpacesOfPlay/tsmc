// Relational comparisons, and the jump each one feeds. A comparison followed by
// a conditional jump compiles to one instruction, so every shape that pair
// takes has to still hold: a loop test, an if and its else, a ternary, a switch
// on true, the short-circuit operators that keep their operand's value rather
// than a boolean, a continue and a break, and a comparison whose value is used
// instead of jumped on. The coercions come with it: strings compare as strings,
// a BigInt against a number, valueOf running once, and NaN unordered.

const T = (l, f) => { try { console.log(l, '->', String(f())); } catch (e) { console.log(l, 'threw', e.constructor.name); } };
T('ints', () => [1 < 2, 2 < 1, 2 <= 2, 3 > 2, 2 >= 3].join(','));
T('strings', () => ['a' < 'b', 'b' <= 'a', 'abc' < 'abd'].join(','));
T('mixed', () => ['2' < 3, 3 < '2', null < 1, undefined < 1].join(','));
T('NaN', () => [NaN < 1, NaN >= 1, NaN <= NaN].join(','));
T('bigint', () => [1n < 2, 2n > 3n, 2n <= 2].join(','));
T('valueOf order', () => { const log = []; const o = { valueOf() { log.push('v'); return 5; } }; const r = o < 6; return [r, log.join('')].join(','); });
T('valueOf throws in an if', () => { const o = { valueOf() { throw new RangeError('x'); } }; if (o < 1) { return 'lt'; } return 'ge'; });
T('symbol compares', () => Symbol() < 1);
T('in a while', () => { let i = 0, s = 0; while (i < 5) { s += i; i++; } return s; });
T('in a for', () => { let s = 0; for (let i = 0; i <= 4; i++) s += i; return s; });
T('in an if/else', () => { const a = 3; if (a > 5) return 'big'; else if (a > 2) return 'mid'; return 'small'; });
T('ternary', () => (3 < 4 ? 'y' : 'n'));
T('and/or keep values', () => [(0 < 1) && 'kept', (1 < 0) || 'other', 5 && 6, 0 || 7].join(','));
T('do-while', () => { let i = 0; do { i++; } while (i < 3); return i; });
T('nested with continue', () => { let s = 0; for (let i = 0; i < 6; i++) { if (i % 2 === 0) continue; s += i; } return s; });
T('break out', () => { let s = 0; for (let i = 0; i < 100; i++) { if (i >= 5) break; s += i; } return s; });
T('switch over a compare', () => { const x = 4; switch (true) { case x < 3: return 'lo'; case x < 10: return 'mid'; default: return 'hi'; } });
T('comparison as a value', () => { const b = 2 < 3; return [b, typeof b].join(','); });
T('optional chain guard', () => { const o = null; return o?.x < 5; });
T('for-of with a compare inside', () => { let s = ''; for (const c of 'abc') { if (c < 'c') s += c; } return s; });

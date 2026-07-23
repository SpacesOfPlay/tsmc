// The legacy `escape` / `unescape` globals and Node's `global` alias.
// `global` and both functions were missing (only `globalThis` existed),
// blocking pure-JS hashing libraries (js-sha256, crypto-js, ...) that check
// `typeof global` or use `unescape(encodeURIComponent(s))` for UTF-8 bytes.
// Compared byte-for-byte against Node.

// global aliases the global object
console.log('global is globalThis:', global === globalThis);
console.log('typeof:', typeof global, typeof escape, typeof unescape);

// escape: unmodified set, %XX for < 256, %uXXXX for the rest
const cases = ['abc123', 'a b+c', '@*_+-./', 'héllo', 'π≈', '<a>&"=', 'x\ty\nz'];
for (const s of cases) console.log('escape', JSON.stringify(s), '->', escape(s));

// round-trip
for (const s of cases) console.log('roundtrip', unescape(escape(s)) === s);

// %uXXXX and mixed
console.log('unescape %u:', unescape('%u0041%u00e9%42'));
console.log('escape astral:', escape('\u{1f600}'));            // surrogate pair -> two %u
console.log('unescape astral:', JSON.stringify(unescape('%uD83D%uDE00')));

// the crypto-js / hashing idiom: UTF-8 bytes as a Latin-1 string
console.log('utf8 idiom:', JSON.stringify(unescape(encodeURIComponent('héllo π'))));

// global carries the built-ins
console.log('global.JSON === JSON:', global.JSON === JSON, 'global.Math === Math:', global.Math === Math);

// escape leaves the unmodified set untouched
console.log('unmodified:', escape('ABCabc012@*_+-./'));

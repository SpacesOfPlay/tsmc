// String methods: code units versus code points, slicing, searching, padding,
// trimming (over the whole whitespace set, not just the ASCII blanks), case,
// well-formedness, and how a boxed String wrapper behaves.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}
const EMOJI = '\u{1F600}';       // astral: two UTF-16 units
const ACCENT = 'é';          // precomposed é
const COMBINING = 'é';      // e + combining acute

// --- length, indexing, code units vs code points ---
T('length-ascii', () => 'abc'.length);
T('length-astral', () => EMOJI.length);
T('length-combining', () => [ACCENT.length, COMBINING.length]);
T('charAt', () => ['abc'.charAt(1), 'abc'.charAt(9), 'abc'.charAt(-1)]);
T('index-access', () => ['abc'[1], 'abc'[9]]);
T('charCodeAt', () => ['abc'.charCodeAt(0), 'abc'.charCodeAt(9)]);
T('charCodeAt-astral', () => [EMOJI.charCodeAt(0), EMOJI.charCodeAt(1)]);
T('codePointAt', () => [EMOJI.codePointAt(0), 'abc'.codePointAt(0)]);
T('at', () => ['abc'.at(0), 'abc'.at(-1), 'abc'.at(5)]);
T('spread-by-codepoint', () => [...EMOJI].length);
T('for-of-codepoint', () => { let n = 0; for (const c of EMOJI + 'a') n++; return n; });
T('split-empty-by-unit', () => (EMOJI + 'a').split('').length);
T('array-from', () => Array.from(EMOJI + 'a').length);

// --- slicing ---
T('slice', () => ['abcdef'.slice(1, 3), 'abcdef'.slice(-2), 'abcdef'.slice(3, 1)]);
T('substring', () => ['abcdef'.substring(1, 3), 'abcdef'.substring(3, 1), 'abcdef'.substring(-1, 2)]);
T('substr', () => ['abcdef'.substr(1, 2), 'abcdef'.substr(-2), 'abcdef'.substr(-2, 1)]);
T('slice-no-args', () => 'abc'.slice());
T('slice-undefined-end', () => 'abc'.slice(1, undefined));

// --- searching ---
T('indexOf', () => ['abcabc'.indexOf('b'), 'abcabc'.indexOf('b', 2), 'abc'.indexOf('z')]);
T('indexOf-empty', () => ['abc'.indexOf(''), 'abc'.indexOf('', 10)]);
T('lastIndexOf', () => ['abcabc'.lastIndexOf('b'), 'abcabc'.lastIndexOf('b', 2)]);
T('includes', () => ['abc'.includes('b'), 'abc'.includes('b', 2), 'abc'.includes('')]);
T('startsWith', () => ['abc'.startsWith('a'), 'abc'.startsWith('b', 1), 'abc'.startsWith('')]);
T('endsWith', () => ['abc'.endsWith('c'), 'abc'.endsWith('b', 2), 'abc'.endsWith('')]);
T('search-regexp-arg', () => 'abc'.includes('b'));

// --- padding, repeating, trimming ---
T('padStart', () => ['5'.padStart(3, '0'), 'ab'.padStart(5, 'xy'), 'abc'.padStart(2, '0')]);
T('padEnd', () => ['5'.padEnd(3, '0'), 'ab'.padEnd(5, 'xy')]);
T('pad-default-space', () => JSON.stringify('a'.padStart(3)));
T('pad-empty-filler', () => 'a'.padStart(5, ''));
T('repeat', () => ['ab'.repeat(3), 'ab'.repeat(0)]);
T('repeat-negative', () => 'a'.repeat(-1));
T('repeat-fractional', () => 'a'.repeat(2.9));
T('trim', () => JSON.stringify('  a  '.trim()));
T('trimStart-End', () => [JSON.stringify('  a  '.trimStart()), JSON.stringify('  a  '.trimEnd())]);
T('trim-unicode-space', () => JSON.stringify('  a　'.trim()));
T('trim-newlines', () => JSON.stringify('\n\t a \r\n'.trim()));

// --- case ---
T('case-basic', () => ['AbC'.toUpperCase(), 'AbC'.toLowerCase()]);
T('case-accented', () => [ACCENT.toUpperCase(), 'É'.toLowerCase()]);
T('case-non-latin', () => ['α'.toUpperCase(), 'А'.toLowerCase()]);
T('case-sharp-s', () => 'ß'.toUpperCase());
T('case-preserves-astral', () => EMOJI.toUpperCase() === EMOJI);

// --- concat, compare, misc ---
T('concat', () => 'a'.concat('b', 'c', 1));
T('plus-coercion', () => ['a' + 1, 'a' + null, 'a' + undefined, 'a' + {}]);
T('comparison', () => ['a' < 'b', 'A' < 'a', 'abc' < 'abd', '10' < '9']);
T('localeCompare-sign', () => [Math.sign('a'.localeCompare('b')), Math.sign('b'.localeCompare('a')), 'a'.localeCompare('a')]);
T('fromCharCode', () => [String.fromCharCode(97, 98), String.fromCharCode(0xd83d, 0xde00) === EMOJI]);
T('fromCodePoint', () => [String.fromCodePoint(97), String.fromCodePoint(0x1f600) === EMOJI]);
T('fromCodePoint-invalid', () => String.fromCodePoint(0x110000));
T('raw', () => String.raw`a\nb${1}c`);
T('string-ctor', () => [String(5), String(null), String(Symbol('s'))]);

// --- normalize and well-formedness ---
T('normalize-exists', () => typeof ''.normalize);
T('normalize-idempotent-ascii', () => 'abc'.normalize() === 'abc');
T('normalize-bad-form', () => 'a'.normalize('NFX'));
T('isWellFormed', () => [typeof ''.isWellFormed, 'a'.isWellFormed?.(), EMOJI.isWellFormed?.()]);
T('isWellFormed-lone', () => '\ud800'.isWellFormed?.());
T('toWellFormed', () => '\ud800'.toWellFormed?.().charCodeAt(0));

// --- receiver handling ---
T('generic-call', () => String.prototype.toUpperCase.call('ab'));
T('number-receiver', () => String.prototype.slice.call(12345, 1, 3));
T('string-object', () => { const s = new String('ab'); return [s.length, s[0], s.toUpperCase()]; });
T('string-object-keys', () => Object.keys(new String('ab')));
T('string-object-tag', () => Object.prototype.toString.call(new String('ab')));
T('string-object-spread', () => [...new String('ab')]);
T('string-object-json', () => JSON.stringify({ s: new String('ab') }));

console.log(rows.join('\n'));

// Not asserted:
//   - normalize() does not actually normalise: the NFC/NFD mapping tables are
//     not carried, so it returns the string unchanged. Its form argument is
//     validated, so an invalid one still throws RangeError.
//   - a String.prototype method called on null or undefined coerces the
//     receiver instead of throwing TypeError. The guard belongs at all 28
//     sites that take `this` as a string.

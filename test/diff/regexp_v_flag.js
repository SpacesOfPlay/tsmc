// The v flag: set notation inside a character class.
//
// [[a-z][0-9]] unions, [[a-z]--[aeiou]] subtracts, [[a-z]&&[h-p]] intersects,
// and classes nest. A class is a union of its operands unless it is a -- or
// && chain, and the two kinds cannot be mixed.
//
// Not supported, and refused rather than misread: \q{...} string literals and
// the properties of strings. Both make a class match more than one character,
// which is a different thing from a set of code points.
//
// Each case filters a string one character at a time, so what comes back is
// the set the class actually holds rather than a yes or no.

const rows = [];
function T(label, fn) {
  let v;
  try { v = JSON.stringify(fn()); }
  catch (e) { v = 'THROW:' + (e && e.name ? e.name : String(e)); }
  rows.push(label + ' = ' + v);
}
const hits = (src, flags, str) => () => {
  const r = new RegExp(src, flags);
  return Array.from(str).filter((ch) => r.test(ch)).join('');
};

// --- union ------------------------------------------------------------------
T('nested-union', hits('[[a-c][0-2]]', 'v', 'abcd012 3z'));
T('mixed-union', hits('[[a-c]x-z]', 'v', 'abcxyzq'));
T('deep-nesting', hits('[[[a-c]]]', 'v', 'abcd'));
T('union-with-escape', hits('[[\\d][a-c]]', 'v', 'a1c9z'));
T('union-of-properties', hits('[\\p{Lu}\\p{Nd}]', 'v', 'aA1!'));

// --- difference -------------------------------------------------------------
T('difference', hits('[[a-z]--[aeiou]]', 'v', 'abcdefghij'));
T('difference-nested', hits('[[a-z]--[m-p]]', 'v', 'klmnopq'));
T('difference-chain', hits('[[a-z]--[a-c]--[x-z]]', 'v', 'abcdwxyz'));
T('difference-property', hits('[\\p{ASCII}--[a-z]]', 'v', 'aA1!z'));
T('difference-single-char', hits('[[a-e]--c]', 'v', 'abcde'));
T('difference-empty-result', hits('[[a-c]--[a-c]]', 'v', 'abc'));
T('difference-astral', () => {
  const r = new RegExp('[[\\u{1F600}-\\u{1F64F}]--[\\u{1F60A}]]', 'v');
  return [r.test('\u{1F600}'), r.test('\u{1F60A}')].join(',');
});

// --- intersection -----------------------------------------------------------
T('intersection', hits('[[a-m]&&[h-z]]', 'v', 'agh mnz'));
T('intersection-chain', hits('[[a-z]&&[a-m]&&[h-p]]', 'v', 'agh mnz'));
T('intersection-property', hits('[\\p{L}&&[a-z0-9]]', 'v', 'a1Z'));
T('intersection-disjoint', hits('[[a-c]&&[x-z]]', 'v', 'acxz'));
T('intersection-negated-operand', hits('[[^a-c]&&[a-e]]', 'v', 'abcde'));
T('intersection-negated-property', hits('[\\P{L}&&[a-z1-9!]]', 'v', 'a1!'));

// --- negation ---------------------------------------------------------------
T('outer-negated-union', hits('[^[a-c][x-z]]', 'v', 'abcmxyz'));
T('outer-negated-difference', hits('[^[a-z]--[aeiou]]', 'v', 'abcde'));
T('plain-class', hits('[a-c]', 'v', 'abcd'));
T('plain-negated', hits('[^a-c]', 'v', 'abcd'));

// --- what the grammar refuses -----------------------------------------------
T('range-as-operand', () => new RegExp('[a-z--[aeiou]]', 'v').source);
T('mixed-operators', () => new RegExp('[[a-z]--[m]&&[a-c]]', 'v').source);
T('leading-operator', () => new RegExp('[--[a]]', 'v').source);
T('trailing-operator', () => new RegExp('[[a-z]--]', 'v').source);
T('triple-ampersand', () => new RegExp('[a&&&b]', 'v').source);
T('reserved-punctuator', () => new RegExp('[(]', 'v').source);
T('reserved-punctuator-escaped', hits('[\\(]', 'v', '(a'));
T('double-punctuator', () => new RegExp('[a!!b]', 'v').source);

// --- the rest of the flag ----------------------------------------------------
T('flags-string', () => new RegExp('a', 'v').flags);
T('unicodeSets-property', () => [new RegExp('a', 'v').unicodeSets, new RegExp('a', 'u').unicodeSets].join(','));
T('source-preserved', () => { const r = new RegExp('[[a-z]--[m]]', 'v'); return r.source + '|' + r.flags; });
T('astral-range', () => new RegExp('[\\u{1F600}-\\u{1F64F}]', 'v').test('\u{1F60A}'));
T('dot-is-code-point', () => new RegExp('.', 'v').exec('\u{1F600}')[0].length);
T('case-insensitive-difference', () => {
  const r = new RegExp('[[a-z]--[m]]', 'vi');
  return [r.test('a'), r.test('m'), r.test('M')].join(',');
});
T('with-quantifier', () => new RegExp('[[a-z]--[aeiou]]+', 'v').exec('rhythm')[0]);
T('in-replace', () => 'hello world'.replace(new RegExp('[[a-z]--[aeiou]]', 'gv'), '.'));
T('in-split', () => 'a1b2c'.split(new RegExp('[[0-9]&&[1-5]]', 'v')).join('|'));
T('u-and-v-together', () => new RegExp('a', 'uv').source);

console.log(rows.join('\n'));

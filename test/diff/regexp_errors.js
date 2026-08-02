// Which regular expressions are refused.
//
// A pattern that should be a SyntaxError but is quietly accepted is the worst
// case of all: the expression then matches something other than what was
// written, and a validation regex that never matches looks like a data
// problem rather than a typo.
//
// Not checked: the v flag's set notation. [\p{ASCII}--[a-z]], [[a-z]&&[aeiou]],
// nested classes and \q{} are refused here with a SyntaxError, where node
// accepts them. That is a loud gap rather than a silent one — the previous
// behaviour was to read them as something else entirely and match nothing —
// but it is still a gap, and the cases below stay away from it. Simple v
// patterns work and are checked.

const rows = [];
function T(label, fn) {
  let v;
  try { v = JSON.stringify(fn()); }
  catch (e) { v = 'THROW:' + (e && e.name ? e.name : String(e)); }
  rows.push(label + ' = ' + v);
}
const make = (src, flags) => () => { const r = new RegExp(src, flags); return 'ok:' + r.source + '/' + r.flags; };

// --- patterns with nothing to repeat ----------------------------------------
T('lone-star', make('*a', ''));
T('lone-plus', make('+a', ''));
T('double-quantifier', make('a**', ''));
T('quantifier-in-group', make('(?:*)', ''));
T('quantified-lookbehind', make('(?<=a)*', ''));
T('quantified-lookahead-annexb', make('(?=a)*', ''));

// --- ranges and counts ------------------------------------------------------
T('backwards-range', make('[b-a]', ''));
T('backwards-range-u', make('[b-a]', 'u'));
T('equal-range', make('[a-a]', ''));
T('backwards-count', make('a{2,1}', ''));
T('equal-count', make('a{2,2}', ''));
T('open-count', make('a{2,}', ''));
T('class-escape-as-range-u', make('[a-\\d]', 'u'));
T('class-escape-as-range-low-u', make('[\\d-a]', 'u'));
T('property-as-range-u', make('[a-\\p{L}]', 'u'));
T('class-escape-range-annexb', make('[a-\\d]', ''));

// --- groups -----------------------------------------------------------------
T('duplicate-group-name', make('(?<a>x)(?<a>y)', ''));
T('digit-leading-group-name', make('(?<1a>x)', ''));
T('punctuation-group-name', make('(?<a-b>x)', ''));
T('valid-group-name', make('(?<a_1$>x)', ''));
T('unclosed-group', make('(a', ''));
T('unclosed-class', make('[a', ''));
T('incomplete-lookahead', make('(?=', ''));

// --- u mode is stricter than the default ------------------------------------
T('lone-brace-u', make('a{', 'u'));
T('lone-brace-annexb', make('a{', ''));
T('lone-bracket-u', make(']', 'u'));
T('lone-bracket-annexb', make(']', ''));
T('octal-escape-u', make('\\101', 'u'));
T('octal-escape-annexb', make('\\101', ''));
T('backref-out-of-range-u', make('(a)\\2', 'u'));
T('backref-in-range-u', make('(a)\\1', 'u'));
T('identity-escape-u', make('\\-', 'u'));
T('identity-escape-in-class-u', make('[\\-]', 'u'));
T('unknown-escape-u', make('\\q', 'u'));
T('unknown-escape-annexb', make('\\q', ''));
T('syntax-escape-u', make('\\{', 'u'));
T('bad-codepoint-u', make('\\u{110000}', 'u'));
T('good-codepoint-u', make('\\u{1F600}', 'u'));
T('unknown-property-u', make('\\p{Nope}', 'u'));
T('property-without-u', make('\\p{L}', ''));

// --- flags ------------------------------------------------------------------
T('invalid-flag', make('a', 'q'));
T('duplicate-flag', make('a', 'gg'));
T('u-and-v-together', make('a', 'uv'));
T('all-valid-flags', make('a', 'dgimsy'));
T('v-alone', make('a', 'v'));
T('v-flags-string', () => new RegExp('a', 'v').flags);
T('v-unicodeSets', () => [new RegExp('a', 'v').unicodeSets, new RegExp('a', 'u').unicodeSets].join(','));
T('v-simple-class', () => { const r = new RegExp('[a-z]', 'v'); return [r.test('m'), r.test('M')].join(','); });
T('v-property', () => new RegExp('\\p{Lu}', 'v').test('A'));
T('v-astral', () => new RegExp('.', 'v').exec('\u{1F600}')[0].length);

// --- what has to keep working -----------------------------------------------
T('property-u', () => new RegExp('\\p{Lu}', 'u').test('A'));
T('codepoint-escape', () => new RegExp('\\u{1F600}', 'u').test('\u{1F600}'));
T('named-group', () => 'ab'.match(new RegExp('(?<x>a)')).groups.x);
T('backref', () => new RegExp('(a)\\1').test('aa'));
T('class-with-dash', () => new RegExp('[\\d-]').test('-'));
T('nested-quantifier', () => new RegExp('(?:ab)+c').test('ababc'));
T('lookbehind', () => new RegExp('(?<=a)b').test('ab'));
T('sticky-and-global', () => { const r = new RegExp('a', 'gy'); return r.flags; });
T('unicode-class-range', () => new RegExp('[\\u{100}-\\u{200}]', 'u').test('\u{150}'));
T('word-boundary', () => new RegExp('\\bword\\b').test('a word here'));
T('multiline-anchors', () => new RegExp('^b', 'm').test('a\nb'));

console.log(rows.join('\n'));

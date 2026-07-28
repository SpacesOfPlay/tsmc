// Bounded repeats {n,m}. The optional copies past the minimum are nested, not
// laid out as independent `?` copies: both accept the same language, but a
// sequence lets the matcher pick any subset, so a failing tail explores
// C(m, length) paths instead of m. That difference used to exhaust the step
// limit on ordinary patterns and report no match at all — the shape below is
// lifted from linkify-it, which builds URL matchers out of {1,50} runs.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}
const M = (re, s) => { const m = re.exec(s); return m && m[0]; };

// The reduced form of the failure: an optional group whose bounded repeat
// cannot reach the trailing literal, so the whole group must match empty.
T('optional-bound-50', () => M(/^(?:.{1,50}@)?/, 'a.com'));
T('optional-bound-200', () => M(/^(?:.{1,200}@)?/, 'a.com'));
T('optional-bound-vs-length', () => ['ab', 'abcd', 'a.com', 'abcdefghij'].map((s) => M(/^(?:.{1,80}@)?/, s)));
T('linkify-auth-shape', () => M(/^(?:(?:(?![ \xA0]|[\0-\x1F]|[@/\[\]()]).){1,50}@)?/, 'a.com'));
T('linkify-auth-matching', () => M(/^(?:(?:(?![ \xA0]|[\0-\x1F]|[@/\[\]()]).){1,50}@)?/, 'user@host'));

// A bounded repeat still has to match what it should.
T('bound-exact', () => M(/^a{3}$/, 'aaa'));
T('bound-too-few', () => M(/^a{3}$/, 'aa'));
T('bound-range-greedy', () => M(/^a{1,3}/, 'aaaa'));
T('bound-range-lazy', () => M(/^a{1,3}?/, 'aaaa'));
T('bound-open-ended', () => M(/^a{2,}/, 'aaaa'));
T('bound-zero-min', () => [M(/^a{0,3}/, 'b'), M(/^a{0,3}/, 'aa')]);
T('bound-backtracks-to-fit', () => M(/^a{1,5}ab/, 'aaab'));
T('bound-with-group', () => M(/^(?:ab){1,3}/, 'ababab'));
T('bound-captures-last', () => { const m = /^(a){1,3}$/.exec('aaa'); return m && m[1]; });
T('bound-nested', () => M(/^(?:(?:a{1,2}){1,3})$/, 'aaaa'));
T('bound-alternation', () => M(/^(?:a|b){1,4}$/, 'abba'));
T('bound-class', () => M(/^[a-z]{2,4}$/, 'abc'));
T('bound-anchored-fail', () => M(/^a{1,50}b$/, 'aaa'));
T('bound-lazy-minimal', () => M(/^a{1,50}?b/, 'aaab'));

// Global scanning over a long subject: the whole run must be found.
T('bound-global-scan', () => 'xx user@host yy admin@site zz'.match(/[a-z]{1,20}@[a-z]{1,20}/g));
T('bound-replace', () => 'aaaa'.replace(/a{1,2}/g, 'X'));
T('bound-split', () => 'a1bb22ccc'.split(/[0-9]{1,2}/));

console.log(rows.join('\n'));

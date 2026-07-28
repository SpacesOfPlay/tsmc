// RegExp semantics: exec/test and how lastIndex moves under /g and /y, flags
// and their properties, named groups and \k<name>, match/matchAll, the
// replacement patterns replace understands, split (including captures), and
// the pattern features themselves.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// --- exec / test and lastIndex ---
T('exec-basic', () => { const m = /b(c)/.exec('abcd'); return [m[0], m[1], m.index, m.input]; });
T('exec-no-match', () => /z/.exec('abc'));
T('exec-global-advances', () => { const r = /a/g; const o = []; let m; while ((m = r.exec('aaa')) !== null) o.push(m.index); return o; });
T('exec-global-lastindex', () => { const r = /a/g; r.exec('aab'); return r.lastIndex; });
T('exec-nonglobal-lastindex', () => { const r = /a/; r.exec('aab'); return r.lastIndex; });
T('test-global-advances', () => { const r = /a/g; return [r.test('aa'), r.lastIndex, r.test('aa'), r.lastIndex, r.test('aa')]; });
T('lastindex-manual', () => { const r = /a/g; r.lastIndex = 1; const m = r.exec('aaa'); return m.index; });
T('lastindex-reset-on-fail', () => { const r = /z/g; r.lastIndex = 2; r.exec('abc'); return r.lastIndex; });
T('sticky-anchors', () => { const r = /a/y; r.lastIndex = 1; return [r.test('ba'), r.lastIndex]; });
T('sticky-fails-off-position', () => { const r = /a/y; r.lastIndex = 0; return r.test('ba'); });
T('exec-groups-undefined', () => { const m = /(a)|(b)/.exec('a'); return [m[1], m[2] === undefined]; });

// --- flags and properties ---
T('flags-string', () => /x/gimsuy.flags);
T('flag-props', () => { const r = /x/gim; return [r.global, r.ignoreCase, r.multiline, r.sticky, r.dotAll]; });
T('source', () => /a\/b/.source);
T('source-empty', () => new RegExp('').source);
T('tostring', () => String(/a/g));
T('ctor-from-string', () => new RegExp('a+', 'g').source);
T('ctor-from-regex', () => new RegExp(/a/g).flags);
T('ctor-regex-with-flags', () => new RegExp(/a/g, 'i').flags);
T('ctor-invalid-throws', () => new RegExp('('));
T('ctor-invalid-flag-throws', () => new RegExp('a', 'q'));

// --- named groups ---
T('named-groups-exec', () => { const m = /(?<y>\d{4})-(?<mo>\d{2})/.exec('2026-07'); return [m.groups.y, m.groups.mo]; });
T('named-groups-absent', () => { const m = /(a)/.exec('a'); return m.groups === undefined; });
T('named-backreference', () => /(?<c>a)\k<c>/.test('aa'));
T('named-in-replace', () => '2026-07'.replace(/(?<y>\d{4})-(?<mo>\d{2})/, '$<mo>/$<y>'));

// --- match / matchAll ---
T('match-nonglobal', () => { const m = 'abcabc'.match(/b(c)/); return [m[0], m[1], m.index]; });
T('match-global', () => 'abcabc'.match(/b/g));
T('match-no-match-global', () => 'x'.match(/b/g));
T('match-no-match', () => 'x'.match(/b/));
T('match-string-arg', () => 'a.b'.match('.')[0]);
T('matchall-basic', () => [...'a1b2'.matchAll(/[a-z](\d)/g)].map((m) => m[1]));
T('matchall-requires-global', () => [...'a1'.matchAll(/a/)]);
T('matchall-index', () => [...'aa'.matchAll(/a/g)].map((m) => m.index));

// --- replace ---
T('replace-string', () => 'abc'.replace('b', 'X'));
T('replace-regex-first', () => 'aaa'.replace(/a/, 'X'));
T('replace-regex-global', () => 'aaa'.replace(/a/g, 'X'));
T('replace-dollar-amp', () => 'abc'.replace(/b/, '[$&]'));
T('replace-dollar-group', () => 'abc'.replace(/(b)/, '[$1]'));
T('replace-dollar-before', () => 'abc'.replace(/b/, '[$`]'));
T('replace-dollar-after', () => "abc".replace(/b/, "[$']"));
T('replace-dollar-dollar', () => 'abc'.replace(/b/, '$$'));
T('replace-unknown-group', () => 'abc'.replace(/(b)/, '$2'));
T('replace-fn-args', () => { let got; 'abc'.replace(/(b)/, function (m, p1, off, s) { got = [m, p1, off, s]; return 'X'; }); return got; });
T('replace-fn-global-count', () => { let n = 0; 'aaa'.replace(/a/g, () => { n++; return 'x'; }); return n; });
T('replace-fn-named-groups', () => { let g; '2026'.replace(/(?<y>\d{4})/, function (...a) { g = a[a.length - 1]; return ''; }); return g.y; });
T('replaceall-string', () => 'aaa'.replaceAll('a', 'X'));
T('replaceall-regex-nonglobal-throws', () => 'aaa'.replaceAll(/a/, 'X'));
T('replaceall-regex-global', () => 'aaa'.replaceAll(/a/g, 'X'));
T('replace-empty-match', () => 'abc'.replace(/(?:)/g, '-'));

// --- split ---
T('split-string', () => 'a,b,c'.split(','));
T('split-regex', () => 'a1b2c'.split(/\d/));
T('split-with-captures', () => 'a1b2c'.split(/(\d)/));
T('split-limit', () => 'a,b,c'.split(',', 2));
T('split-empty-regex', () => 'abc'.split(/(?:)/));
T('split-no-match', () => 'abc'.split(/z/));
T('split-empty-string', () => ''.split(','));
T('split-leading-trailing', () => ',a,'.split(','));
T('split-captures-undefined', () => 'ab'.split(/(x)|(b)/));

// --- search ---
T('search-found', () => 'abc'.search(/b/));
T('search-not-found', () => 'abc'.search(/z/));
T('search-ignores-lastindex', () => { const r = /a/g; r.lastIndex = 2; return 'aaa'.search(r); });

// --- pattern features ---
T('lookahead', () => /a(?=b)/.test('ab'));
T('neg-lookahead', () => /a(?!b)/.test('ac'));
T('lookbehind', () => /(?<=a)b/.test('ab'));
T('neg-lookbehind', () => /(?<!a)b/.test('cb'));
T('backreference', () => /(a)\1/.test('aa'));
T('lazy-quantifier', () => /a.*?b/.exec('axbxb')[0]);
T('greedy-quantifier', () => /a.*b/.exec('axbxb')[0]);
T('anchors-multiline', () => 'a\nb'.match(/^b$/m)[0]);
T('anchors-no-multiline', () => /^b$/.test('a\nb'));
T('dotall', () => [/a.b/s.test('a\nb'), /a.b/.test('a\nb')]);
T('word-boundary', () => 'a b'.match(/\bb\b/)[0]);
T('char-class-negate', () => /[^a]/.exec('ab')[0]);
T('alternation-order', () => /a|ab/.exec('ab')[0]);
T('quantifier-braces', () => /a{2,3}/.exec('aaaa')[0]);
T('unicode-escape', () => /\u{1F600}/u.test('\u{1F600}'));
T('case-insensitive', () => /ABC/i.test('abc'));
T('escaped-metachar', () => /a\.b/.test('a.b'));
T('nested-groups', () => { const m = /((a)(b))/.exec('ab'); return [m[1], m[2], m[3]]; });
T('noncapturing', () => { const m = /(?:a)(b)/.exec('ab'); return [m[1], m.length]; });

// `\k<name>` naming no group at all stays a literal escape rather than an
// error, which is what a pattern with no named groups relies on.
T('k-literal-when-no-named-group', () => new RegExp('\\k<nope>').test('k<nope>'));
T('k-literal-under-unicode', () => new RegExp('\\k<nope>', 'u').test('k<nope>'));
T('k-unknown-name-with-named-group', () => new RegExp('(?<a>x)\\k<nope>').test('x'));
T('k-forward-reference', () => /\k<fwd>(?<fwd>b)/.test('bb'));
T('k-lookbehind-is-not-a-group', () => new RegExp('(?<=a)\\k<nope>').test('k<nope>'));

console.log(rows.join('\n'));

// RegExp: matching, the stateful global/sticky behaviour, capture groups and
// every replacement pattern.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

T('test', () => [/a/.test('abc'), /z/.test('abc')]);
T('exec-basic', () => { const m = /b/.exec('abc'); return [m[0], m.index, m.input, m.length]; });
T('exec-groups', () => { const m = /(a)(b)/.exec('ab'); return [m[0], m[1], m[2], m.length]; });
T('exec-no-match', () => /z/.exec('abc'));
T('exec-optional-group', () => { const m = /(a)(z)?/.exec('a'); return [m[1], m[2] === undefined, m.length]; });
T('named-groups', () => { const m = /(?<y>\d{4})-(?<m>\d{2})/.exec('2020-01'); return [m.groups.y, m.groups.m]; });
T('named-groups-absent', () => { const m = /(a)/.exec('a'); return m.groups; });

T('lastIndex-global', () => { const r = /a/g; const a = r.exec('aa'); const i1 = r.lastIndex; const b = r.exec('aa'); return [i1, r.lastIndex, b.index]; });
T('lastIndex-reset', () => { const r = /a/g; r.exec('aa'); r.exec('aa'); return [r.exec('aa'), r.lastIndex]; });
T('lastIndex-nonglobal', () => { const r = /a/; r.exec('aa'); return r.lastIndex; });
T('test-global-advances', () => { const r = /a/g; return [r.test('aa'), r.test('aa'), r.test('aa')]; });
T('sticky', () => { const r = /a/y; r.lastIndex = 1; return [r.test('ba'), r.lastIndex]; });
T('sticky-fails-off-position', () => { const r = /a/y; r.lastIndex = 0; return r.test('ba'); });

T('flags-string', () => [/a/gi.flags, /a/.flags, /a/msuy.flags]);
T('flag-props', () => { const r = /a/gi; return [r.global, r.ignoreCase, r.multiline, r.dotAll, r.sticky, r.unicode]; });
T('source', () => [/ab+c/.source, new RegExp('x\\d').source]);
T('toString', () => String(/ab/gi));
T('ctor-from-string', () => new RegExp('a+', 'g').test('aaa'));
T('ctor-from-regexp', () => new RegExp(/a/g).flags);

T('ignoreCase', () => [/ABC/i.test('abc'), /ABC/.test('abc')]);
T('multiline', () => [/^b/m.test('a\nb'), /^b/.test('a\nb')]);
T('dotAll', () => [/a.b/s.test('a\nb'), /a.b/.test('a\nb')]);
T('anchors', () => [/^a$/.test('a'), /^a$/.test('ba')]);
T('word-boundary', () => [/\bcat\b/.test('a cat here'), /\bcat\b/.test('concat')]);
T('char-classes', () => [/\d/.test('5'), /\w/.test('_'), /\s/.test('\t'), /\D/.test('a')]);
T('negated-class', () => /[^abc]/.test('d'));
T('quantifiers', () => [/a{2}/.test('aa'), /a{2,}/.test('aaa'), /a{2,3}/.test('aa'), /a+?/.exec('aaa')[0]]);
T('alternation', () => /^(cat|dog)$/.test('dog'));
T('backreference', () => [/(a)\1/.test('aa'), /(a)\1/.test('ab')]);
T('lookahead', () => [/a(?=b)/.test('ab'), /a(?=b)/.test('ac'), /a(?!b)/.test('ac')]);
T('lookbehind', () => [/(?<=a)b/.test('ab'), /(?<!a)b/.test('cb')]);
T('unicode-prop', () => [/\p{Lu}/u.test('A'), /\p{Lu}/u.test('a')]);
T('unicode-astral', () => [/^.$/u.test('😀'), /^.$/.test('😀')]);
T('escaped-metachars', () => /a\.b/.test('a.b'));
T('nested-groups', () => { const m = /((a)(b))/.exec('ab'); return [m[1], m[2], m[3]]; });
T('non-capturing', () => { const m = /(?:a)(b)/.exec('ab'); return [m[1], m.length]; });

T('match-global', () => 'a1b2'.match(/\d/g));
T('match-nonglobal', () => { const m = 'a1b2'.match(/\d/); return [m[0], m.index]; });
T('match-none', () => 'abc'.match(/\d/g));
T('matchAll', () => [...'a1b2'.matchAll(/(\d)/g)].map((m) => [m[0], m[1], m.index]));
T('search', () => ['abc'.search(/b/), 'abc'.search(/z/)]);

T('replace-string', () => 'abc'.replace('b', 'X'));
T('replace-regex', () => 'abc'.replace(/b/, 'X'));
T('replace-global', () => 'aaa'.replace(/a/g, 'X'));
T('replace-dollar-amp', () => 'abc'.replace(/b/, '<$&>'));
T('replace-dollar-group', () => 'abc'.replace(/(b)/, '[$1]'));
T('replace-dollar-named', () => '2020-01'.replace(/(?<y>\d{4})-(?<m>\d{2})/, '$<m>/$<y>'));
T('replace-dollar-before', () => 'abc'.replace(/b/, '[$`]'));
T('replace-dollar-after', () => 'abc'.replace(/b/, "[$']"));
T('replace-dollar-literal', () => 'abc'.replace(/b/, '$$'));
T('replace-fn-args', () => 'abc'.replace(/(b)/, (m, p1, off, s) => [m, p1, off, s].join('|')));
T('replace-fn-global-index', () => 'aaa'.replace(/a/g, (m, i) => i));
T('replace-fn-named', () => '2020'.replace(/(?<y>\d{4})/, (...a) => JSON.stringify(a[a.length - 1])));
T('replaceAll-string', () => 'aaa'.replaceAll('a', 'X'));
T('replaceAll-regex-global', () => 'aaa'.replaceAll(/a/g, 'X'));
T('replaceAll-nonglobal-throws', () => 'aaa'.replaceAll(/a/, 'X'));

T('split-regex', () => 'a1b2c'.split(/\d/));
T('split-limit', () => 'a1b2c'.split(/\d/, 2));
T('split-empty-regex', () => 'ab'.split(/(?:)/));
T('split-no-match', () => 'abc'.split(/z/));

console.log(rows.join('\n'));

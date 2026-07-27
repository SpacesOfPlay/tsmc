// Dense coverage of String.prototype and the String statics. Each case is
// labelled so a divergence names itself; a throw is reported by its
// constructor, so a method going missing shows up as clearly as a wrong value.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

const s = 'Hello, World';

T('at', () => s.at(-1));
T('at-oob', () => s.at(99));
T('charAt', () => s.charAt(1));
T('charCodeAt', () => s.charCodeAt(0));
T('codePointAt', () => '😀'.codePointAt(0));
T('concat', () => 'a'.concat('b', 'c'));
T('endsWith', () => [s.endsWith('World'), s.endsWith('Hello')]);
T('includes', () => s.includes('lo,'));
T('indexOf', () => [s.indexOf('o'), s.indexOf('zz')]);
T('lastIndexOf', () => s.lastIndexOf('o'));
T('localeCompare', () => ['a'.localeCompare('b'), 'b'.localeCompare('a'), 'a'.localeCompare('a')]);
T('padStart', () => ['5'.padStart(3, '0'), 'abc'.padStart(2, '0')]);
T('padEnd', () => '5'.padEnd(3, '0'));
T('repeat', () => ['ab'.repeat(3), 'a'.repeat(0)]);
T('repeat-negative', () => 'a'.repeat(-1));
T('replace', () => s.replace('World', 'There'));
T('replace-fn', () => 'abc'.replace(/b/, (m) => m.toUpperCase()));
T('replace-dollar', () => 'abc'.replace(/(b)/, '[$1]'));
T('replace-dollar-amp', () => 'abc'.replace(/b/, '<$&>'));
T('replaceAll', () => 'aaa'.replaceAll('a', 'b'));
T('search', () => [s.search(/World/), s.search(/zz/)]);
T('slice', () => [s.slice(-5), s.slice(0, 5), s.slice(5, 2)]);
T('split', () => s.split(', '));
T('split-empty', () => 'abc'.split(''));
T('split-limit', () => 'a,b,c'.split(',', 2));
T('split-regex', () => 'a1b2c'.split(/\d/));
T('startsWith', () => s.startsWith('Hello'));
T('startsWith-pos', () => s.startsWith('World', 7));
T('substring', () => [s.substring(0, 5), s.substring(5, 0)]);
T('substr', () => s.substr(7, 5));
T('toLowerCase', () => s.toLowerCase());
T('toUpperCase', () => s.toUpperCase());
T('trim', () => '  x  '.trim());
T('trimStart', () => '  x  '.trimStart());
T('trimEnd', () => '  x  '.trimEnd());
T('match', () => 'a1b2'.match(/\d/g));
T('match-none', () => 'abc'.match(/\d/g));
T('match-named', () => 'ab'.match(/(?<x>a)/).groups.x);
T('matchAll', () => [...'a1b2'.matchAll(/\d/g)].map((m) => m[0]));
T('raw', () => String.raw`a\nb`);
T('fromCharCode', () => String.fromCharCode(65, 66));
T('fromCodePoint', () => String.fromCodePoint(0x1F600).length);
T('iterator-astral', () => [...'a😀b'].length);
T('length-astral', () => '😀'.length);
T('compare', () => ['a' < 'b', 'b' < 'a', 'abc' < 'abd']);
T('template', () => `${1 + 1}x`);
T('concat-coerce', () => ['a' + 1, 1 + 'a', 'a' + null, 'a' + undefined]);
T('String-ctor', () => [String(5), String(null), String(undefined), String([1, 2])]);
T('valueOf-boxed', () => typeof new String('a').valueOf());
T('indexOf-fromIndex', () => 'aaa'.indexOf('a', 1));
T('slice-oob', () => 'abc'.slice(10));
T('charAt-oob', () => 'abc'.charAt(10));

console.log(rows.join('\n'));

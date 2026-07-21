'use strict';
// npm compatibility probe for doc/npm-compatibility.md.
//
// Exercises each package with a real call (not just require) and prints one
// tab-separated line per package: <PASS|FAIL>\t<name>\t<result-or-error>.
// Run the same file under Node and tsmc and compare line by line — a package
// "works" only when the two outputs match. Install the packages first (see
// doc/npm-compatibility.md for the exact versions).
function t(name, fn) {
  try {
    const r = fn();
    console.log('PASS\t' + name + '\t' + String(r).slice(0, 40).replace(/\n/g, ' '));
  } catch (e) {
    const msg = (e && e.message ? e.message : e).toString().split('\n')[0];
    console.log('FAIL\t' + name + '\t' + msg.slice(0, 60));
  }
}

// utility & data
t('ms', () => require('ms')('2 days'));
t('bytes', () => require('bytes')(1024));
t('deepmerge', () => JSON.stringify(require('deepmerge')({ a: 1 }, { b: 2 })));
t('classnames', () => require('classnames')('a', { b: true }));
t('clsx', () => require('clsx')('a', { b: true }));
t('escape-string-regexp', () => require('escape-string-regexp')('a.b*c'));
t('eventemitter3', () => { const E = require('eventemitter3'); const e = new E(); let v = 0; e.on('x', n => v = n); e.emit('x', 9); return v; });
t('fast-deep-equal', () => require('fast-deep-equal')({ a: [1, 2] }, { a: [1, 2] }));
t('fast-json-stable-stringify', () => require('fast-json-stable-stringify')({ b: 2, a: 1 }));

// ids
t('uuid', () => require('uuid').v4().length);
t('nanoid', () => require('nanoid').nanoid().length);

// text & strings
t('he', () => require('he').encode('<a>'));
t('strip-ansi', () => require('strip-ansi')('[31mx[39m'));
t('pluralize', () => require('pluralize')('cat', 2));
t('dedent', () => require('dedent')('  a\n  b'));

// parsing & config
t('js-yaml', () => JSON.stringify(require('js-yaml').load('a: [1,2]')));
t('json5', () => require('json5').parse('{a:1,/*c*/b:2,}').b);
t('ini', () => JSON.stringify(require('ini').parse('a=1\nb=2')));
t('query-string', () => require('query-string').stringify({ a: 1, b: 2 }));

// templating
t('mustache', () => require('mustache').render('{{a}}', { a: 'z' }));

// validation & versioning
t('validator', () => require('validator').isEmail('a@b.co'));
t('semver', () => require('semver').gt('2.0.0', '1.0.0'));

// dates
t('date-fns', () => require('date-fns').format(new Date(2020, 0, 1), 'yyyy'));
t('dayjs', () => require('dayjs')('2020-01-01').year());

// numbers
t('big.js', () => new (require('big.js'))(0.1).plus(0.2).toString());

// terminal color
t('picocolors', () => require('picocolors').red('x').length);
t('kleur', () => require('kleur').red('x').length);
t('colorette', () => require('colorette').blue('x').length);

// --- known-failing today (kept so the doc's blocker list stays honest) ---
t('lodash', () => require('lodash').chunk([1, 2, 3], 2).length);       // new Function
t('qs', () => require('qs').stringify({ a: 1 }));                      // eval
t('immer', () => require('immer').produce({ a: 1 }, d => { d.a = 2; }).a);  // Proxy/Reflect
t('markdown-it', () => require('markdown-it')().render('# h'));       // slice.call on array-like
t('bignumber.js', () => new (require('bignumber.js'))('0.1').toString());  // parser
t('camelcase', () => require('camelcase')('foo-bar'));               // regex \p{} -> wrong output

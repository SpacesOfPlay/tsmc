// url module: the legacy API (parse/format/resolve), file-path conversions,
// urlToHttpOptions and the IDNA helpers. Platform-neutral: every file-URL
// case fixes `windows` explicitly and no relative path touches the cwd.
// No input whose host part carries a colon (`urn:a:b`, `http://[::1 ]/`):
// node answers those with a deprecation warning on stderr, which the
// harness compares too.
const url = require('url');
const http = require('http');

function show(label, v) {
  console.log(label, typeof v === 'string' ? JSON.stringify(v) : JSON.stringify(v));
}
function err(label, fn) {
  try { const r = fn(); console.log(label, 'no error', JSON.stringify(r)); }
  catch (e) { console.log(label, e.name, e.code, JSON.stringify(e.message), e.input === undefined ? '' : JSON.stringify(e.input)); }
}

console.log('--- exports');
console.log(Object.keys(url).sort().join(' '));
console.log(url.URL === URL, url.URLSearchParams === URLSearchParams, typeof url.Url);

console.log('--- parse');
const parseCases = [
  'http://www.example.com/path?query=1#frag',
  'HTTP://USER:PW@EXAMPLE.COM:8080/P/A/T/H?q=1#h',
  'http://a@b@c/',
  'http://a@b?@c',
  'http://[fe80::1]:8080/a',
  'http://[::1]/',
  'http://x.com/a b c',
  'http://x.com/a"b<c>d^e`f{g|h}i',
  'http://x.com:/',
  'http://x.com:8/',
  'http://x.com',
  'https://x.com',
  'http://x.com?q',
  'http://x.com#h',
  'http://x.com/#?query',
  'http://x.com/?a#b?c',
  'http:///a',
  'http://example.com\\foo\\bar',
  '  http://x.com/a  ',
  '\thttp://x.com/a\n',
  'http://x.com/a\tb\nc',
  'http://ñ.com/',
  'http://ÉXAMPLE.com/',
  'http://user:pa ss@x.com/',
  'http://user%20name:p%40ss@x.com/',
  'http://x.com/a%20b?c%20d#e f',
  'http://255.255.255.255/',
  'http://x.com/a/./b/../c',
  'ws://x.com',
  'wss://x.com/a?b',
  'ftp://ftp.example.com/',
  'file:///etc/passwd',
  'file://localhost/etc/passwd',
  'file:///C:/x/y',
  'mailto:local1@domain1,local2@domain2',
  'mailto:me@x.com?subject=hi',
  'javascript:alert(1)',
  'javascript://x.com/a b',
  'xmpp:isaacschlueter@jabber.org',
  'about:blank',
  'data:text/plain,hi there',
  'urn:isbn:0451450523',
  'git+ssh://git@github.com/npm/npm',
  'coap://[1080:0:0:0:8:800:200C:417A]:61616/',
  'http://x.com/%zz',
  'HTTP://x.com/UPPER',
  'http://x.com:65536/',
  'http://a.b.c.d.e.f/',
  'http://x.com/;a=b',
  '//some_path',
  '//some/path?q=1',
  '///three',
  '/foo/bar?baz=quux',
  '/foo/bar?baz=quux#h',
  '/foo bar',
  '/',
  '?q=1',
  '#h',
  '',
  'foo',
  'foo/bar',
  'foo?bar',
  'foo@bar',
  'C:\\foo\\bar',
  'c:/foo',
  'x.com:8080/a',
  'user@host',
  '"http://x.com"',
  'http://x.com/a?b=c&b=d&e',
  'http://x.com/?a=1&a=2&b',
];
for (const c of parseCases) {
  let r;
  try { r = url.parse(c); } catch (e) { r = e.name + ' ' + e.code; }
  show(JSON.stringify(c), r);
}

console.log('--- parse with parseQueryString');
for (const c of ['http://x.com/?a=1&a=2&b', 'http://x.com/path', '/p?x=y+z&w=%41', '/p', 'http://x.com/?#h', 'mailto:a@b?subject=hi&x=1']) {
  const r = url.parse(c, true);
  show(JSON.stringify(c), r);
  console.log('  query proto:', Object.getPrototypeOf(r.query) === null, Object.keys(r.query).join(','));
}

console.log('--- parse with slashesDenoteHost');
for (const c of ['//some_path', '//host/path?q', '//host', '/one', 'foo', '//user@host:8080/x']) {
  show(JSON.stringify(c), url.parse(c, false, true));
}

console.log('--- parse: Url instance is returned as is');
const once = url.parse('http://x.com/a');
console.log(url.parse(once) === once, once instanceof url.Url);
console.log(Object.keys(new url.Url()).join(','));

console.log('--- format');
const formatCases = [
  { protocol: 'http:', host: 'x.com', pathname: '/a', search: '?b=1', hash: '#c' },
  { protocol: 'http', hostname: 'x.com', port: 8080, pathname: 'a' },
  { protocol: 'http:', slashes: true, hostname: 'x.com' },
  { protocol: 'http:', hostname: 'x.com', query: { a: 1, b: [2, 3], c: 'x y' } },
  { protocol: 'http:', hostname: 'x.com', search: 'a=1', query: { ignored: 1 } },
  { protocol: 'http:', hostname: 'x.com', hash: 'frag' },
  { protocol: 'http:', hostname: 'x.com', pathname: '/a#b?c' },
  { protocol: 'http:', hostname: 'x.com', search: '?a#b' },
  { protocol: 'http:', hostname: '::1', port: 80, pathname: '/' },
  { protocol: 'http:', hostname: '[::1]', port: 80, pathname: '/' },
  { protocol: 'http:', auth: 'user:pa ss@x', hostname: 'x.com' },
  { protocol: 'http:', auth: 'ünï', hostname: 'x.com' },
  { protocol: 'mailto:', auth: 'me', host: 'x.com' },
  { protocol: 'file:', pathname: '/etc/passwd' },
  { protocol: 'file:', slashes: true, pathname: '/etc/passwd' },
  { protocol: 'javascript:', pathname: 'alert(1)' },
  { slashes: true, host: 'x.com', pathname: '/a' },
  { pathname: '/a', search: '?b' },
  { pathname: 'rel', search: 'b' },
  { host: 'x.com', hostname: 'ignored.com', port: 99 },
  { protocol: 'https:', host: 'x.com:443', pathname: '/' },
  {},
];
for (const c of formatCases) show(JSON.stringify(c), url.format(c));
show('string', url.format('HTTP://X.com/a b?c#d'));
show('Url', url.format(url.parse('http://u:p@x.com:81/a?b#c')));

console.log('--- format(URL, options)');
const wu = new URL('https://user:pass@xn--espaol-zwa.com:8443/a/b?c=1#frag');
show('plain', url.format(wu));
show('no fragment', url.format(wu, { fragment: false }));
show('no search', url.format(wu, { search: false }));
show('no auth', url.format(wu, { auth: false }));
show('unicode', url.format(wu, { unicode: true }));
show('all off', url.format(wu, { fragment: false, search: false, auth: false, unicode: true }));
show('ascii host unicode', url.format(new URL('http://example.com/x'), { unicode: true }));
show('mailto', url.format(new URL('mailto:me@x.com?subject=hi'), { search: false }));

console.log('--- resolve');
const base = 'http://a/b/c/d;p?q';
const rfc = ['g', './g', 'g/', '/g', '//g', '?y', 'g?y', '#s', 'g#s', 'g?y#s', ';x', 'g;x',
  'g;x?y#s', '', '.', './', '..', '../', '../g', '../..', '../../', '../../g', '../../../g',
  '../../../../g', '/./g', '/../g', 'g.', '.g', 'g..', '..g', './../g', './g/.', 'g/./h',
  'g/../h', 'g;x=1/./y', 'g;x=1/../y', 'g?y/./x', 'g?y/../x', 'g#s/./x', 'g#s/../x', 'http:g'];
for (const r of rfc) show(JSON.stringify(r), url.resolve(base, r));
const pairs = [
  ['/foo/bar/baz', 'quux'], ['/foo/bar/baz', 'quux/asdf'], ['/foo/bar/baz', 'quux/baz'],
  ['/foo/bar/baz', '../quux/baz'], ['/foo/bar/baz', '/bar'], ['/foo/bar/baz', '//bar'],
  ['/foo/bar/baz', 'http://x.com/y'], ['/foo/bar/baz', '?q'], ['/foo/bar/baz', '#h'],
  ['/foo/bar/baz', ''], ['/foo/bar/baz', '.'], ['/foo/bar/baz', '..'], ['/foo/bar/baz', '../../..'],
  ['/foo/bar/baz', '../../../../x'],
  ['foo/bar/baz', 'quux'], ['foo/bar/baz', '../quux'], ['foo/bar/baz', '../../../quux'], ['foo', 'bar'],
  ['', 'foo'], ['foo', ''], ['', ''],
  ['http://example.com/', '/one'], ['http://example.com/one', '/two'], ['http://example.com/one', 'two'],
  ['http://example.com/one/', 'two'], ['http://example.com/one/two', '../three'],
  ['http://example.com/one/two/three', '../../four'], ['http://example.com', 'x'], ['http://example.com', '/x'],
  ['http://example.com/a/', 'b/../../../c'], ['http://example.com/a?b', '?c'], ['http://example.com/a?b', '#c'],
  ['http://example.com/a#b', ''], ['http://u:p@x.com/a', '//y.com/b'], ['http://u:p@x.com/a', '//x.com/b'],
  ['http://u:p@x.com/a', '/b'], ['http://x.com/a', 'HTTP://Y.com/z'], ['http://x.com/a', 'https://y.com/z'],
  ['http://x.com/a', 'https:/z'], ['http://x.com/a', 'https:z'], ['http://x.com/a', 'https:'],
  ['http://x.com/a', 'mailto:me@x'], ['mailto:local@x', 'bob@y'], ['mailto:local@x', '?subject=hi'],
  ['mailto:local@x', 'http://y.com/'], ['http://x.com/a', 'file:///etc/passwd'],
  ['http://x.com/a', 'javascript:alert(1)'], ['file:///a/b', 'c'], ['file:///a/b', '/c'],
  ['http://x.com/b//c//d;p?q#blarg', 'https:#hash2'], ['http://x.com/b//c//d;p?q#blarg', 'https:/p/a/t/h?s#hash2'],
  ['http://x.com/b//c//d;p?q#blarg', 'https://u:p@h.com/p/a/t/h?s#hash2'], ['http://x.com/b//c//d;p?q#blarg', 'https:/a/b/c/d'],
  ['http://x.com/a/b', 'c/d/'], ['http://x.com/a/b/', 'c/d/'], ['http://x.com/a/b', '../'], ['http://x.com/a/b', '..'],
  ['http://x.com/a/b', '.'], ['http://[::1]:80/a', 'b'], ['http://x.com:8080/a', '//y.com:9090/b'],
  ['http://x.com', '?'], ['http://x.com/', '#'], ['/', 'a'], ['a', '/'], ['a/', '/b'],
  ['http://x.com/a b', 'c d'], ['http://x.com/a', 'b\\c'], ['http://x.com/a/', '../../../b'],
];
for (const [a, b] of pairs) console.log(JSON.stringify(a), JSON.stringify(b), '->', JSON.stringify(url.resolve(a, b)));

console.log('--- resolveObject');
show('object', url.resolveObject('http://x.com/a/b?c', '../d?e#f'));
show('string relative', url.resolveObject(url.parse('http://x.com/a/b'), 'c'));
show('empty source', url.resolveObject('', 'c'));
const ro = url.resolveObject('http://x.com/a/b', url.parse('c?d', true));
show('parsed relative', ro);

console.log('--- fileURLToPath');
const w = { windows: true }, p = { windows: false };
for (const c of ['file:///C:/path/to/file.txt', 'file:///C:/a%20b/c', 'file:///c:/x', 'file://server/share/x%20y',
  'file://xn--espaol-zwa.com/share', 'file:///C:/x%2Fy', 'file:///C:/x%5cy', 'file:///foo', 'file:///C:', 'file:///C:/', 'file:///C:/%C3%A9']) {
  err(JSON.stringify(c) + ' win', () => url.fileURLToPath(c, w));
}
for (const c of ['file:///home/a%20b', 'file:///x%2Fy', 'file:///x%5Cy', 'file://host/x', 'file://localhost/x', 'file:///', 'file:///%C3%A9/ü']) {
  err(JSON.stringify(c) + ' posix', () => url.fileURLToPath(c, p));
}
err('http scheme', () => url.fileURLToPath('http://x.com/a', p));
err('number', () => url.fileURLToPath(123, p));
err('object', () => url.fileURLToPath({}, p));
err('URL object', () => url.fileURLToPath(new URL('file:///tmp/x%20y'), p));
console.log(typeof url.fileURLToPath('file:///tmp/x', p));

console.log('--- pathToFileURL');
for (const c of ['C:\\a b\\c%d#e?f', 'C:\\dir\\', 'C:\\dir', 'c:/mixed/sep\\x', 'C:\\ü\\é', 'C:\\a\tb', '\\\\server\\share\\x y', '\\\\server\\share\\',
  '\\\\?\\UNC\\srv\\sh\\x', '\\\\server', '\\\\\\x', 'C:\\x\\..\\y\\.\\z', 'C:\\']) {
  err(JSON.stringify(c) + ' win', () => url.pathToFileURL(c, w).href);
}
for (const c of ['/home/a b/c%d#e?f', '/x\\y', '/dir/', '/dir', '/a\nb\tc\rd', '/ü/é', '/x/../y/./z', '/', '/a/b/..']) {
  err(JSON.stringify(c) + ' posix', () => url.pathToFileURL(c, p).href);
}
err('number', () => url.pathToFileURL(123));
console.log(url.pathToFileURL('/tmp/x', p) instanceof URL);

console.log('--- urlToHttpOptions');
for (const c of ['https://u:p%40w@ex.com:8443/a/b?c=1#d', 'http://ex.com/', 'http://[::1]:3000/x?y', 'http://u@ex.com/']) {
  const o = url.urlToHttpOptions(new URL(c));
  console.log(JSON.stringify(c), Object.getPrototypeOf(o) === null, JSON.stringify(o));
}

console.log('--- domainToASCII / domainToUnicode');
for (const c of ['español.com', 'xn--espaol-zwa.com', 'example.com', 'EXAMPLE.com', 'xn--iñvalid.com', 'a b', '', '中文.example', 'xn--fiq228c.example', 'a.b.c.', '1.2.3.4', 'x_y.com']) {
  console.log(JSON.stringify(c), JSON.stringify(url.domainToASCII(c)), JSON.stringify(url.domainToUnicode(c)));
}
err('no arg', () => url.domainToASCII());

console.log('--- errors');
err('parse number', () => url.parse(123));
err('parse undefined', () => url.parse());
err('parse object', () => url.parse({}));
err('parse bad host', () => url.parse('http://x y.com/'));
err('parse bad host 2', () => url.parse('http://x%20y/'));
err('format null', () => url.format(null));
err('format number', () => url.format(123));
err('format bad options', () => url.format(new URL('http://x/'), 5));

console.log('--- STATUS_CODES');
console.log(Object.keys(http.STATUS_CODES).length, http.STATUS_CODES[100], http.STATUS_CODES[418], http.STATUS_CODES[426], http.STATUS_CODES[511], http.STATUS_CODES[999]);

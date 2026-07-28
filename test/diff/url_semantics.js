// URL and URLSearchParams: parsing, the component setters, and the query
// string. All of it is fixed by the WHATWG spec, so nothing here depends on
// the host.
//
// The components are accessors over hidden slots rather than a snapshot, so
// the checks below deliberately mix reading and writing: assigning to one
// component has to be visible through every other, and through searchParams,
// which serialises itself back into the query.

const out = [];

function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}

function T(label, fn) {
  let v;
  try { v = fn(); } catch (e) {
    v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e));
  }
  out.push(label + ' = ' + show(v));
}

const parts = (u) => [u.protocol, u.username, u.password, u.hostname, u.port,
                      u.pathname, u.search, u.hash];

// --- parsing ----------------------------------------------------------------

T('full', () => parts(new URL('https://user:pw@example.com:8443/a/b?x=1&y=2#frag')));
T('href-roundtrip', () => new URL('https://example.com:8443/a?x=1#f').href);
T('minimal', () => parts(new URL('http://example.com')));
T('default-port-http', () => new URL('http://example.com:80/a').href);
T('default-port-https', () => new URL('https://example.com:443/a').href);
T('nondefault-port-kept', () => new URL('https://example.com:8443/a').port);
T('port-empty-for-default', () => new URL('http://example.com:80/').port);
T('host-vs-hostname', () => {
  const u = new URL('https://example.com:8443/');
  return [u.host, u.hostname];
});
T('origin', () => [new URL('https://a.com:8443/x').origin, new URL('http://a.com/x').origin]);
T('origin-nonspecial', () => new URL('mailto:a@b.com').origin);
T('lowercases-scheme-host', () => parts(new URL('HTTPS://EXAMPLE.COM/PaTh')));
T('empty-path-becomes-slash', () => new URL('http://a.com').pathname);
T('nonspecial-scheme', () => parts(new URL('mailto:someone@example.com')));
T('data-url', () => {
  const u = new URL('data:text/plain,hello');
  return [u.protocol, u.pathname, u.host];
});
T('file-url', () => parts(new URL('file:///c:/dir/file.txt')));
T('ipv6-host', () => {
  const u = new URL('http://[2001:db8::1]:8080/p');
  return [u.hostname, u.host, u.port];
});
T('ipv4-host', () => new URL('http://192.168.0.1/').hostname);
T('credentials-only-user', () => {
  const u = new URL('https://user@example.com/');
  return [u.username, u.password, u.href];
});
T('dot-segments', () => new URL('http://a.com/x/../y/./z').pathname);
T('dot-segments-above-root', () => new URL('http://a.com/../../a').pathname);
T('double-slash-path', () => new URL('http://a.com//p//q').pathname);
T('query-only', () => {
  const u = new URL('http://a.com/?');
  return [u.search, u.href];
});
T('hash-only', () => {
  const u = new URL('http://a.com/#');
  return [u.hash, u.href];
});
T('hash-with-query-chars', () => new URL('http://a.com/#a?b=c').hash);
T('trims-whitespace', () => new URL('  http://a.com/p  ').href);
T('strips-tab-newline', () => new URL('http://a.com/p\tq\nr').href);
T('percent-in-path-kept', () => new URL('http://a.com/a%20b').pathname);
T('space-in-path-encoded', () => new URL('http://a.com/a b').pathname);
T('unicode-in-path', () => new URL('http://a.com/caf\u00e9').pathname);
T('unicode-in-query', () => new URL('http://a.com/?q=caf\u00e9').search);
T('backslash-in-special', () => new URL('http://a.com\\p').pathname);
T('invalid-no-scheme', () => new URL('not a url'));
T('invalid-empty', () => new URL(''));
T('invalid-scheme-only', () => new URL('http://'));
T('tojson-is-href', () => {
  const u = new URL('http://a.com/p?q=1');
  return [u.toJSON() === u.href, JSON.stringify({ u })];
});
T('tostring-is-href', () => String(new URL('http://a.com/p')) === new URL('http://a.com/p').href);

// --- relative resolution ----------------------------------------------------

T('rel-absolute-path', () => new URL('/x/y', 'http://a.com/p/q?s#h').href);
T('rel-relative-path', () => new URL('x/y', 'http://a.com/p/q').href);
T('rel-dotdot', () => new URL('../z', 'http://a.com/p/q/r').href);
T('rel-query-only', () => new URL('?new', 'http://a.com/p?old#h').href);
T('rel-hash-only', () => new URL('#new', 'http://a.com/p?q#old').href);
T('rel-empty', () => new URL('', 'http://a.com/p?q#h').href);
T('rel-protocol-relative', () => new URL('//other.com/p', 'https://a.com/x').href);
T('rel-absolute-wins', () => new URL('https://b.com/x', 'http://a.com/y').href);
T('rel-base-is-url-object', () => new URL('p', new URL('http://a.com/base/')).href);
T('rel-base-invalid', () => new URL('p', 'not a base'));
T('rel-scheme-change-not-allowed', () => new URL('mailto:x@y.com', 'http://a.com/').href);
T('canParse', () => typeof URL.canParse === 'function'
  ? [URL.canParse('http://a.com'), URL.canParse('nope'), URL.canParse('p', 'http://a.com')]
  : 'missing');

// --- setters ----------------------------------------------------------------

T('set-protocol', () => { const u = new URL('http://a.com/p'); u.protocol = 'https:'; return u.href; });
T('set-protocol-no-colon', () => { const u = new URL('http://a.com/p'); u.protocol = 'https'; return u.href; });
T('set-hostname', () => { const u = new URL('http://a.com/p'); u.hostname = 'b.org'; return u.href; });
T('set-host-with-port', () => { const u = new URL('http://a.com/p'); u.host = 'b.org:99'; return [u.hostname, u.port, u.href]; });
T('set-port', () => { const u = new URL('http://a.com/p'); u.port = '8080'; return u.href; });
T('set-port-default-clears', () => { const u = new URL('http://a.com:8080/p'); u.port = '80'; return [u.port, u.href]; });
T('set-port-empty', () => { const u = new URL('http://a.com:8080/p'); u.port = ''; return [u.port, u.href]; });
T('set-pathname', () => { const u = new URL('http://a.com/p'); u.pathname = '/new/path'; return u.href; });
T('set-pathname-no-slash', () => { const u = new URL('http://a.com/p'); u.pathname = 'rel'; return u.pathname; });
T('set-search-with-qmark', () => { const u = new URL('http://a.com/p'); u.search = '?a=1'; return [u.search, u.href]; });
T('set-search-without-qmark', () => { const u = new URL('http://a.com/p'); u.search = 'a=1'; return u.search; });
T('set-search-empty', () => { const u = new URL('http://a.com/p?x=1'); u.search = ''; return [u.search, u.href]; });
T('set-hash', () => { const u = new URL('http://a.com/p'); u.hash = 'top'; return [u.hash, u.href]; });
T('set-hash-empty', () => { const u = new URL('http://a.com/p#x'); u.hash = ''; return [u.hash, u.href]; });
T('set-username-password', () => {
  const u = new URL('http://a.com/p');
  u.username = 'me'; u.password = 'secret';
  return u.href;
});
T('set-href', () => { const u = new URL('http://a.com/p'); u.href = 'https://b.org:1/q?r#s'; return parts(u); });
T('set-href-invalid', () => { const u = new URL('http://a.com/p'); u.href = 'garbage'; return u.href; });
T('set-search-updates-params', () => {
  const u = new URL('http://a.com/p?a=1');
  u.search = 'b=2';
  return [u.searchParams.get('a'), u.searchParams.get('b')];
});
T('params-update-search', () => {
  const u = new URL('http://a.com/p?a=1');
  u.searchParams.set('b', '2');
  return [u.search, u.href];
});
T('params-delete-clears-search', () => {
  const u = new URL('http://a.com/p?a=1');
  u.searchParams.delete('a');
  return [u.search, u.href];
});
T('searchParams-identity', () => {
  const u = new URL('http://a.com/?a=1');
  return u.searchParams === u.searchParams;
});

// --- URLSearchParams --------------------------------------------------------

T('usp-from-string', () => new URLSearchParams('a=1&b=2').toString());
T('usp-leading-qmark', () => new URLSearchParams('?a=1').get('a'));
T('usp-from-object', () => new URLSearchParams({ a: '1', b: '2' }).toString());
T('usp-from-pairs', () => new URLSearchParams([['a', '1'], ['b', '2']]).toString());
T('usp-from-usp', () => new URLSearchParams(new URLSearchParams('a=1')).toString());
T('usp-from-map', () => new URLSearchParams(new Map([['a', '1']])).toString());
T('usp-empty', () => [new URLSearchParams().toString(), new URLSearchParams('').toString()]);
T('usp-get-missing', () => new URLSearchParams('a=1').get('zz'));
T('usp-getAll', () => new URLSearchParams('a=1&a=2&b=3').getAll('a'));
T('usp-getAll-missing', () => new URLSearchParams('a=1').getAll('zz'));
T('usp-has', () => {
  const p = new URLSearchParams('a=1&b=');
  return [p.has('a'), p.has('b'), p.has('c')];
});
T('usp-append-duplicates', () => {
  const p = new URLSearchParams('a=1');
  p.append('a', '2');
  return [p.toString(), p.get('a'), p.getAll('a')];
});
T('usp-set-replaces-all', () => {
  const p = new URLSearchParams('a=1&a=2&b=3');
  p.set('a', 'z');
  return p.toString();
});
T('usp-set-appends-when-absent', () => {
  const p = new URLSearchParams('a=1');
  p.set('c', '3');
  return p.toString();
});
T('usp-delete-all-matching', () => {
  const p = new URLSearchParams('a=1&b=2&a=3');
  p.delete('a');
  return p.toString();
});
T('usp-size', () => new URLSearchParams('a=1&a=2&b=3').size);
T('usp-sort-stable', () => {
  const p = new URLSearchParams('b=2&a=1&b=1&a=2');
  p.sort();
  return p.toString();
});
T('usp-iteration-order', () => [...new URLSearchParams('b=2&a=1')]);
T('usp-keys-values', () => {
  const p = new URLSearchParams('a=1&b=2');
  return [[...p.keys()], [...p.values()]];
});
T('usp-entries', () => [...new URLSearchParams('a=1').entries()]);
T('usp-forEach', () => {
  const seen = [];
  new URLSearchParams('a=1&b=2').forEach((v, k) => seen.push(k + '=' + v));
  return seen;
});
T('usp-no-value', () => {
  const p = new URLSearchParams('a&b=');
  return [p.get('a'), p.get('b'), p.toString()];
});
T('usp-plus-is-space', () => new URLSearchParams('a=one+two').get('a'));
T('usp-percent-decode', () => new URLSearchParams('a=one%20two&b=%26').get('a') + '|' +
                              new URLSearchParams('b=%26').get('b'));
T('usp-encodes-space-as-plus', () => new URLSearchParams({ a: 'one two' }).toString());
T('usp-encodes-specials', () => new URLSearchParams({ 'k&y': 'v=1#2' }).toString());
T('usp-keeps-unreserved', () => new URLSearchParams({ a: "-_.!~*'()" }).toString());
T('usp-unicode', () => new URLSearchParams({ a: 'caf\u00e9' }).toString());
T('usp-coerces-values', () => new URLSearchParams({ n: 1, b: true, u: null }).toString());
T('usp-tostringtag', () => Object.prototype.toString.call(new URLSearchParams()));
T('usp-in-url-toString', () => {
  const u = new URL('http://a.com/');
  u.searchParams.append('q', 'a b');
  return u.href;
});

console.log(out.join('\n'));

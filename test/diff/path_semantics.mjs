// path: the platform module plus the posix and win32 namespaces.
//
// The default export follows the host, so those checks are compared against
// node on the same machine. The posix and win32 namespaces are fixed by the
// spec and read the same anywhere, which is most of what is checked here.
//
// `matchesGlob` is deliberately not covered: it is still experimental in node.

import path from 'path';

const S = String.fromCharCode(92);   // one backslash
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

// --- default (host) module --------------------------------------------------

T('sep', () => path.sep);
T('delimiter', () => path.delimiter);
T('has-posix', () => typeof path.posix);
T('has-win32', () => typeof path.win32);
T('members', () => ['format', 'relative', 'toNamespacedPath']
  .map((k) => k + ':' + typeof path[k]).join(' '));

T('join-simple', () => path.join('a', 'b', 'c'));
T('join-dotdot', () => path.join('a', '..', 'b'));
T('join-trailing', () => path.join('/x/', 'y'));
T('join-empty-args', () => path.join());
T('join-empty-strings', () => path.join('', 'a', ''));
T('join-absolute-mid', () => path.join('a', '/b', 'c'));
T('join-only-dots', () => path.join('.', '..'));

T('normalize-dots', () => path.normalize('a/./b/../c'));
T('normalize-trailing-dotdot', () => path.normalize('a/b/c/..'));
T('normalize-leading-dot', () => path.normalize('./x'));
T('normalize-above-root', () => path.normalize('/../..'));
T('normalize-above-rel', () => path.normalize('../../a'));
T('normalize-empty', () => path.normalize(''));
T('normalize-keeps-trailing-sep', () => path.normalize('a/b/'));
T('normalize-dup-seps', () => path.normalize('a//b///c'));

T('dirname-abs', () => path.dirname('/a/b/c'));
T('dirname-bare', () => path.dirname('a'));
T('dirname-trailing', () => path.dirname('a/b/'));
T('dirname-root', () => path.dirname('/'));
T('dirname-dot', () => path.dirname('.'));
T('dirname-empty', () => path.dirname(''));

T('basename-file', () => path.basename('/a/b/c.txt'));
T('basename-strip-ext', () => path.basename('/a/b/c.txt', '.txt'));
T('basename-trailing', () => path.basename('a/b/'));
T('basename-ext-mismatch', () => path.basename('/a/b.txt', '.md'));
T('basename-ext-is-whole', () => path.basename('/a/.txt', '.txt'));
T('basename-root', () => path.basename('/'));
T('basename-empty', () => path.basename(''));

T('extname-simple', () => path.extname('index.html'));
T('extname-multi', () => path.extname('a.b.c'));
T('extname-dotfile', () => path.extname('.bashrc'));
T('extname-none', () => path.extname('noext'));
T('extname-trailing-dot', () => path.extname('file.'));
T('extname-dir-dot', () => path.extname('a.b/c'));
T('extname-double-dot', () => path.extname('..'));

T('isAbsolute', () => [path.isAbsolute('/a'), path.isAbsolute('a/b'), path.isAbsolute('.'),
                       path.isAbsolute('')]);

T('parse-abs', () => path.parse('/home/user/file.txt'));
T('parse-rel', () => path.parse('a/b.txt'));
T('parse-dotfile', () => path.parse('/x/.env'));
T('parse-noext', () => path.parse('/x/name'));
T('parse-empty', () => path.parse(''));

T('format-from-parse', () => path.format(path.parse('/home/user/file.txt')));
T('format-dir-base', () => path.format({ dir: '/a/b', base: 'c.txt' }));
T('format-root-base', () => path.format({ root: '/', base: 'c.txt' }));
T('format-name-ext', () => path.format({ dir: '/a', name: 'c', ext: '.txt' }));
T('format-base-wins', () => path.format({ dir: '/a', base: 'b.txt', name: 'ignored', ext: '.md' }));
T('format-empty', () => path.format({}));
T('format-name-only', () => path.format({ name: 'solo' }));

T('relative-sibling', () => path.relative('/a/b', '/a/c'));
T('relative-down', () => path.relative('/a', '/a/b/c'));
T('relative-up', () => path.relative('/a/b/c', '/a'));
T('relative-same', () => path.relative('/a/b', '/a/b'));
T('relative-root', () => path.relative('/', '/a'));
T('relative-rel-args', () => path.relative('a/b', 'a/c'));

T('resolve-consistent', () => path.resolve('a', 'b') === path.resolve('.', 'a', 'b'));
T('resolve-is-absolute', () => path.isAbsolute(path.resolve('x')));
T('resolve-empty', () => path.resolve('') === path.resolve('.'));
// a later absolute argument discards everything before it
T('resolve-absolute-wins', () => path.resolve('/a', '/b', 'c') === path.resolve('/b', 'c'));
T('resolve-rooted-keeps-root', () => path.isAbsolute(path.resolve('/a', '/b', 'c')));

// --- posix namespace (fixed everywhere) -------------------------------------

const px = path.posix;

T('px-sep', () => [px.sep, px.delimiter]);
T('px-join', () => px.join('a', 'b', 'c'));
T('px-join-abs', () => px.join('/a', '../b'));
T('px-normalize', () => [px.normalize('/a/./b/../c/'), px.normalize('a//b'), px.normalize('/../x')]);
T('px-dirname', () => [px.dirname('/a/b/c'), px.dirname('/a'), px.dirname('a'), px.dirname('/')]);
T('px-basename', () => [px.basename('/a/b.txt'), px.basename('/a/b.txt', '.txt'), px.basename('/a/b/')]);
T('px-extname', () => [px.extname('a.txt'), px.extname('a.'), px.extname('.x'), px.extname('a')]);
T('px-isAbsolute', () => [px.isAbsolute('/a'), px.isAbsolute('a'), px.isAbsolute('C:/a')]);
T('px-parse', () => px.parse('/home/u/f.tar.gz'));
T('px-format', () => px.format({ root: '/', dir: '/home/u', base: 'f.txt' }));
T('px-relative', () => [px.relative('/a/b', '/a/c'), px.relative('/a', '/a/b'), px.relative('/a/b', '/a/b')]);
T('px-resolve', () => px.resolve('/a', 'b', '../c'));
// a backslash is an ordinary character to the posix flavour
T('px-backslash-is-ordinary', () => px.basename('a' + S + 'b'));
T('px-nested-posix', () => px.posix === px);

// --- win32 namespace (fixed everywhere) -------------------------------------

const w = path.win32;

T('w-sep', () => [w.sep, w.delimiter]);
T('w-join', () => w.join('a', 'b', 'c'));
T('w-join-mixed-seps', () => w.join('a/b', 'c' + S + 'd'));
T('w-normalize', () => [w.normalize('a' + S + '.' + S + 'b' + S + '..' + S + 'c'),
                        w.normalize('C:' + S + 'a' + S + '..' + S + 'b')]);
// the leading double separator of a UNC root is part of the root, not a
// duplicate to be folded away
T('w-normalize-unc', () => [w.normalize(S + S + 'srv' + S + 'share' + S + 'a' + S + '..' + S + 'b'),
                            w.normalize('//srv/share/x'),
                            w.normalize(S + S + 'srv' + S + 'share' + S + '.' + S + 'y')]);
T('w-resolve-unc', () => w.resolve(S + S + 'srv' + S + 'share', 'a', '..', 'b'));
T('w-relative-unc', () => w.relative(S + S + 'srv' + S + 'share' + S + 'a',
                                     S + S + 'srv' + S + 'share' + S + 'b'));
T('w-dirname', () => [w.dirname('C:' + S + 'a' + S + 'b'), w.dirname('C:' + S),
                      w.dirname(S + S + 'srv' + S + 'share' + S + 'x')]);
T('w-basename', () => [w.basename('C:' + S + 'a' + S + 'b.txt'),
                       w.basename('C:' + S + 'a' + S + 'b.txt', '.txt')]);
T('w-extname', () => [w.extname('C:' + S + 'a' + S + 'b.txt'), w.extname('a.b' + S + 'c')]);
T('w-isAbsolute', () => [w.isAbsolute('C:' + S + 'a'), w.isAbsolute('C:/a'),
                         w.isAbsolute(S + S + 'srv' + S + 's'), w.isAbsolute('a'), w.isAbsolute(S + 'x')]);
T('w-parse-drive', () => w.parse('C:' + S + 'home' + S + 'u' + S + 'f.txt'));
T('w-parse-unc', () => w.parse(S + S + 'srv' + S + 'share' + S + 'f.txt'));
T('w-format', () => w.format({ root: 'C:' + S, dir: 'C:' + S + 'a', base: 'b.txt' }));
T('w-relative', () => [w.relative('C:' + S + 'a' + S + 'b', 'C:' + S + 'a' + S + 'c'),
                       w.relative('C:' + S + 'a', 'C:' + S + 'a' + S + 'b' + S + 'c')]);
// nothing relative connects two drives, so the destination is the answer
T('w-relative-cross-drive', () => w.relative('C:' + S + 'a', 'D:' + S + 'b'));
T('w-relative-case-insensitive', () => w.relative('C:' + S + 'A' + S + 'b', 'c:' + S + 'a' + S + 'd'));
T('w-resolve', () => w.resolve('C:' + S + 'a', 'b', '..', 'c'));
T('w-toNamespaced', () => w.toNamespacedPath('C:' + S + 'a' + S + 'b'));
T('w-nested-win32', () => w.win32 === w);
T('w-cross-reference', () => [path.posix.win32 === path.win32, path.win32.posix === path.posix]);

// --- root boundaries: nothing sits above a root, and a root has no basename --

T('w-root-dirname', () => [w.dirname('C:' + S), w.dirname('C:'), w.dirname('C:a' + S + 'b'),
                           w.dirname(S + S + 'srv' + S + 'share' + S)]);
T('w-root-basename', () => [w.basename('C:' + S), w.basename('C:'), w.basename('C:a'),
                            w.basename(S + S + 'srv' + S + 'share' + S)]);
T('w-root-parse', () => [w.parse('C:' + S), w.parse(S + S + 'srv' + S + 'share' + S)]);
T('px-root-dirname', () => [px.dirname('/'), px.dirname('/a'), px.dirname('/a/')]);
T('px-root-basename', () => [px.basename('/'), px.basename('/a/')]);
T('px-root-parse', () => [px.parse('/'), px.parse('/a')]);
T('w-relative-into-root', () => [w.relative('C:' + S, 'C:' + S + 'a'),
                                 w.relative('C:' + S + 'a', 'C:' + S)]);
T('w-format-root-only', () => w.format({ root: 'C:' + S }));
T('px-format-root-only', () => px.format({ root: '/' }));
// the posix flavour has no namespaced form and hands the argument back
T('px-toNamespaced-passthrough', () => [px.toNamespacedPath('/a/b'), px.toNamespacedPath(5)]);
T('w-toNamespaced-unc', () => w.toNamespacedPath(S + S + 'srv' + S + 'share' + S + 'f'));

// --- argument types ---------------------------------------------------------

// a path function rejects a non-string rather than coercing it, so a stray
// number cannot become a path segment
T('argtypes', () => ['join', 'dirname', 'basename', 'extname', 'normalize', 'isAbsolute', 'parse']
  .map((k) => {
    try { path[k](5); return k + ':no-throw'; } catch (e) { return k + ':' + e.constructor.name; }
  }).join(' '));
T('argtype-join-second', () => {
  try { return path.join('a', 5); } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('argtype-suffix', () => {
  try { return path.basename('a.txt', 5); } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('argtype-format', () => {
  try { return path.format('x'); } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('argtype-relative', () => {
  try { return path.relative('a', 5); } catch (e) { return 'THROW:' + e.constructor.name; }
});

// --- extname / parse on dotty names ----------------------------------------

// a leading dot names a hidden file rather than an extension, and a component
// of exactly ".." refers to the parent directory
T('dotty-extname', () => ['..', '...', '....', '.', 'a.', 'a..', '.a', '..a', '.a.b', 'a.b.']
  .map((n) => JSON.stringify(n) + '->' + JSON.stringify(px.extname(n))).join(' '));
T('dotty-parse', () => ['..', '...', '..a', '.a.b'].map((n) => {
  const q = px.parse(n);
  return n + '{name:' + JSON.stringify(q.name) + ',ext:' + JSON.stringify(q.ext) + '}';
}).join(' '));

console.log(out.join('\n'));

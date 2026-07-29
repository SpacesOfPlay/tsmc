// fs: the sync surface, the error shapes real code branches on, and the
// callback and promise spellings.
//
// Everything happens inside one scratch directory next to this file, created
// fresh and removed at the end, so the output does not depend on what was
// there before. Nothing host-specific is printed -- no absolute paths, no
// timestamps, no inode numbers.

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '.fs-sweep');

const out = [];

function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (Buffer.isBuffer(v)) return 'buf<' + v.toString('hex') + '>';
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}

function T(label, fn) {
  let v;
  try { v = fn(); } catch (e) {
    v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)) +
        (e && e.code ? ':' + e.code : '');
  }
  out.push(label + ' = ' + show(v));
}

// An error reduced to the parts a caller actually branches on.
function errShape(fn) {
  try { fn(); return 'no-throw'; } catch (e) {
    return [e.constructor.name, e.code, typeof e.message === 'string' && e.message.length > 0,
            e.syscall === undefined ? 'no-syscall' : typeof e.syscall,
            e.path === undefined ? 'no-path' : (typeof e.path === 'string')];
  }
}

const P = (...p) => path.join(ROOT, ...p);

// --- setup ------------------------------------------------------------------

T('setup', () => {
  fs.rmSync(ROOT, { recursive: true, force: true });
  fs.mkdirSync(ROOT, { recursive: true });
  return fs.existsSync(ROOT);
});

// --- write and read ---------------------------------------------------------

T('write-read-utf8', () => {
  fs.writeFileSync(P('a.txt'), 'hello');
  return fs.readFileSync(P('a.txt'), 'utf8');
});
T('read-returns-buffer-by-default', () => {
  const b = fs.readFileSync(P('a.txt'));
  return [Buffer.isBuffer(b), b.length, b.toString('utf8')];
});
T('read-encoding-in-options', () => fs.readFileSync(P('a.txt'), { encoding: 'utf8' }));
T('write-buffer', () => {
  fs.writeFileSync(P('b.bin'), Buffer.from([1, 2, 255]));
  return fs.readFileSync(P('b.bin'));
});
T('write-overwrites', () => {
  fs.writeFileSync(P('a.txt'), 'first');
  fs.writeFileSync(P('a.txt'), 'second');
  return fs.readFileSync(P('a.txt'), 'utf8');
});
T('append', () => {
  fs.writeFileSync(P('c.txt'), 'one');
  fs.appendFileSync(P('c.txt'), '-two');
  return fs.readFileSync(P('c.txt'), 'utf8');
});
T('append-creates', () => {
  fs.appendFileSync(P('new.txt'), 'x');
  return fs.readFileSync(P('new.txt'), 'utf8');
});
T('write-empty', () => {
  fs.writeFileSync(P('empty.txt'), '');
  return [fs.readFileSync(P('empty.txt'), 'utf8'), fs.statSync(P('empty.txt')).size];
});
T('write-multibyte', () => {
  fs.writeFileSync(P('u.txt'), 'café\u{1f600}');
  const b = fs.readFileSync(P('u.txt'));
  return [b.length, b.toString('utf8')];
});
T('write-hex-encoding', () => {
  fs.writeFileSync(P('h.bin'), 'ff00', 'hex');
  return fs.readFileSync(P('h.bin'));
});

// --- existence and stat -----------------------------------------------------

T('existsSync', () => [fs.existsSync(P('a.txt')), fs.existsSync(P('nope.txt')),
                       fs.existsSync(ROOT)]);
T('statSync-file', () => {
  fs.writeFileSync(P('s.txt'), '12345');
  const st = fs.statSync(P('s.txt'));
  return [st.isFile(), st.isDirectory(), st.size];
});
T('statSync-dir', () => {
  const st = fs.statSync(ROOT);
  return [st.isFile(), st.isDirectory()];
});
T('statSync-mtime-shape', () => {
  const st = fs.statSync(P('s.txt'));
  return [st.mtime instanceof Date, typeof st.mtimeMs, st.mtimeMs > 0];
});
T('statSync-missing', () => errShape(() => fs.statSync(P('nope.txt'))));
T('lstatSync', () => typeof fs.lstatSync === 'function'
  ? [fs.lstatSync(P('s.txt')).isFile(), fs.lstatSync(ROOT).isDirectory()] : 'missing');

// --- directories ------------------------------------------------------------

T('mkdir-readdir', () => {
  fs.mkdirSync(P('sub'));
  fs.writeFileSync(P('sub', 'inner.txt'), 'i');
  return fs.readdirSync(P('sub'));
});
T('mkdir-existing', () => errShape(() => fs.mkdirSync(P('sub'))));
T('mkdir-recursive-ok-if-present', () => {
  fs.mkdirSync(P('sub'), { recursive: true });
  return 'no-throw';
});
T('mkdir-recursive-deep', () => {
  fs.mkdirSync(P('x', 'y', 'z'), { recursive: true });
  return fs.existsSync(P('x', 'y', 'z'));
});
T('mkdir-missing-parent', () => errShape(() => fs.mkdirSync(P('no', 'parent'))));
T('readdir-sorted-contents', () => {
  fs.mkdirSync(P('list'));
  fs.writeFileSync(P('list', 'b.txt'), '');
  fs.writeFileSync(P('list', 'a.txt'), '');
  fs.mkdirSync(P('list', 'd'));
  return fs.readdirSync(P('list')).slice().sort();
});
T('readdir-withFileTypes', () => {
  const es = fs.readdirSync(P('list'), { withFileTypes: true });
  if (!es.length || typeof es[0] !== 'object') return 'missing';
  return es.slice().sort((x, y) => (x.name < y.name ? -1 : 1))
    .map((e) => e.name + ':' + (e.isDirectory() ? 'dir' : 'file'));
});
T('readdir-missing', () => errShape(() => fs.readdirSync(P('nope'))));
T('readdir-on-file', () => errShape(() => fs.readdirSync(P('a.txt'))));
T('read-a-directory', () => errShape(() => fs.readFileSync(ROOT)));

// --- moving, copying, removing ---------------------------------------------

T('copyFileSync', () => {
  fs.writeFileSync(P('src.txt'), 'copy me');
  fs.copyFileSync(P('src.txt'), P('dst.txt'));
  return [fs.readFileSync(P('dst.txt'), 'utf8'), fs.existsSync(P('src.txt'))];
});
T('copyFileSync-missing-source', () => errShape(() => fs.copyFileSync(P('nope.txt'), P('x.txt'))));
T('renameSync', () => {
  fs.writeFileSync(P('old.txt'), 'r');
  fs.renameSync(P('old.txt'), P('newname.txt'));
  return [fs.existsSync(P('old.txt')), fs.readFileSync(P('newname.txt'), 'utf8')];
});
T('renameSync-missing', () => errShape(() => fs.renameSync(P('nope.txt'), P('x.txt'))));
T('unlinkSync', () => {
  fs.writeFileSync(P('gone.txt'), 'g');
  fs.unlinkSync(P('gone.txt'));
  return fs.existsSync(P('gone.txt'));
});
T('unlinkSync-missing', () => errShape(() => fs.unlinkSync(P('nope.txt'))));
T('rmdirSync-empty', () => {
  fs.mkdirSync(P('empty-dir'));
  fs.rmdirSync(P('empty-dir'));
  return fs.existsSync(P('empty-dir'));
});
T('rmdirSync-nonempty', () => {
  fs.mkdirSync(P('full-dir'));
  fs.writeFileSync(P('full-dir', 'f.txt'), '');
  return errShape(() => fs.rmdirSync(P('full-dir')));
});
T('rmSync-recursive', () => {
  fs.rmSync(P('full-dir'), { recursive: true });
  return fs.existsSync(P('full-dir'));
});
T('rmSync-force-missing', () => {
  fs.rmSync(P('never-existed'), { force: true });
  return 'no-throw';
});
T('rmSync-missing-without-force', () => errShape(() => fs.rmSync(P('never-existed'))));

// --- reading a missing file -------------------------------------------------

T('readFileSync-missing', () => errShape(() => fs.readFileSync(P('nope.txt'))));
T('writeFileSync-bad-dir', () => errShape(() => fs.writeFileSync(P('no', 'where.txt'), 'x')));

// --- constants and access ---------------------------------------------------

T('constants', () => typeof fs.constants === 'object'
  ? ['F_OK', 'R_OK', 'W_OK'].map((k) => k + ':' + typeof fs.constants[k]).join(' ')
  : 'missing');
T('accessSync', () => typeof fs.accessSync === 'function'
  ? [(() => { try { fs.accessSync(P('a.txt')); return 'ok'; } catch (e) { return e.code; } })(),
     (() => { try { fs.accessSync(P('nope.txt')); return 'ok'; } catch (e) { return e.code; } })()]
  : 'missing');
T('realpathSync', () => typeof fs.realpathSync === 'function'
  ? path.basename(fs.realpathSync(P('a.txt'))) : 'missing');

// --- the async spellings ----------------------------------------------------

const log = [];

function callbackTests() {
  return new Promise((resolve) => {
    fs.readFile(P('a.txt'), 'utf8', (err, data) => {
      log.push('readFile:' + (err ? 'ERR' : data));
      fs.readFile(P('nope.txt'), 'utf8', (err2, d2) => {
        log.push('readFile-missing:' + (err2 ? err2.code : 'no-error') +
                 ':' + (d2 === undefined ? 'undefined-data' : 'has-data'));
        fs.writeFile(P('cb.txt'), 'written', (err3) => {
          log.push('writeFile:' + (err3 ? 'ERR' : fs.readFileSync(P('cb.txt'), 'utf8')));
          resolve();
        });
      });
    });
  });
}

async function promiseTests() {
  const fsp = fs.promises;
  if (!fsp) { log.push('promises:missing'); return; }
  log.push('promises-readFile:' + await fsp.readFile(P('a.txt'), 'utf8'));
  await fsp.writeFile(P('p.txt'), 'promised');
  log.push('promises-writeFile:' + fs.readFileSync(P('p.txt'), 'utf8'));
  try {
    await fsp.readFile(P('nope.txt'));
    log.push('promises-missing:no-error');
  } catch (e) {
    log.push('promises-missing:' + e.code);
  }
  const names = await fsp.readdir(P('sub'));
  log.push('promises-readdir:' + names.slice().sort().join(','));
  const st = await fsp.stat(P('a.txt'));
  log.push('promises-stat:' + st.isFile());
}

async function main() {
  await callbackTests();
  await promiseTests();
  for (const line of log) out.push('async ' + line);
  T('teardown', () => {
    fs.rmSync(ROOT, { recursive: true, force: true });
    return fs.existsSync(ROOT);
  });
  console.log(out.join('\n'));
}

main();

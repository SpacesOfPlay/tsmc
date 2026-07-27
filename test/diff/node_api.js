// Dense coverage of the implemented Node module surface: path, Buffer, util,
// events, assert, and the URL globals.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

const path = require('path');
T('path-join', () => path.join('a', 'b', '..', 'c'));
T('path-join-absolute', () => path.join('/a', 'b'));
T('path-normalize', () => path.normalize('a//b/./c/..'));
T('path-basename', () => [path.basename('/a/b.txt'), path.basename('/a/b.txt', '.txt')]);
T('path-extname', () => [path.extname('a.tar.gz'), path.extname('a'), path.extname('.hidden')]);
T('path-dirname', () => [path.dirname('/a/b/c'), path.dirname('a')]);
T('path-parse', () => { const q = path.parse('/a/b.txt'); return [q.base, q.ext, q.name]; });
T('path-isAbsolute', () => [path.isAbsolute('/a'), path.isAbsolute('a')]);
T('path-sep-type', () => typeof path.sep);

T('buffer-from-str', () => Buffer.from('abc').toString('hex'));
T('buffer-from-array', () => Buffer.from([1, 2, 3]).length);
T('buffer-alloc', () => Buffer.alloc(3).toString('hex'));
T('buffer-concat', () => Buffer.concat([Buffer.from('a'), Buffer.from('b')]).toString());
T('buffer-base64', () => Buffer.from('hi').toString('base64'));
T('buffer-from-base64', () => Buffer.from('aGk=', 'base64').toString());
T('buffer-hex-round-trip', () => Buffer.from('6869', 'hex').toString());
T('buffer-slice', () => Buffer.from('abcd').slice(1, 3).toString());
T('buffer-subarray', () => Buffer.from('abcd').subarray(0, 2).toString());
T('buffer-equals', () => [Buffer.from('a').equals(Buffer.from('a')), Buffer.from('a').equals(Buffer.from('b'))]);
T('buffer-indexOf', () => [Buffer.from('abc').indexOf('b'), Buffer.from('abc').indexOf('z')]);
T('buffer-includes', () => Buffer.from('abc').includes('b'));
T('buffer-isBuffer', () => [Buffer.isBuffer(Buffer.alloc(1)), Buffer.isBuffer('x')]);
T('buffer-byteLength', () => [Buffer.byteLength('abc'), Buffer.byteLength('😀')]);
T('buffer-json', () => JSON.stringify(Buffer.from([1, 2])));
T('buffer-utf8-astral', () => Buffer.from('😀').length);
T('buffer-index-access', () => { const b = Buffer.from([7, 8]); return [b[0], b.length]; });
T('buffer-fill', () => Buffer.alloc(3).fill(1).toString('hex'));
T('buffer-write', () => { const b = Buffer.alloc(3); b.write('ab'); return b.toString('utf8', 0, 2); });

const util = require('util');
T('util-format-s-d', () => util.format('%s-%d', 'a', 5));
T('util-format-j', () => util.format('%j', { a: 1 }));
T('util-format-extra', () => util.format('%s', 'a', 'b'));
T('util-inspect-obj', () => util.inspect({ a: 1 }));
T('util-inspect-nested', () => util.inspect({ a: [1, 2] }));
T('util-types', () => [util.types.isDate(new Date()), util.types.isRegExp(/a/), util.types.isMap(new Map())]);

const events = require('events');
T('events-emit', () => { const e = new events.EventEmitter(); let got = null; e.on('x', (v) => got = v); e.emit('x', 5); return got; });
T('events-emit-returns', () => { const e = new events.EventEmitter(); return [e.emit('none'), (e.on('y', () => { }), e.emit('y'))]; });
T('events-once', () => { const e = new events.EventEmitter(); let n = 0; e.once('x', () => n++); e.emit('x'); e.emit('x'); return n; });
T('events-listenerCount', () => { const e = new events.EventEmitter(); e.on('x', () => { }); return e.listenerCount('x'); });
T('events-off', () => { const e = new events.EventEmitter(); const f = () => { }; e.on('x', f); e.off('x', f); return e.listenerCount('x'); });
T('events-order', () => { const e = new events.EventEmitter(); const o = []; e.on('x', () => o.push(1)); e.on('x', () => o.push(2)); e.emit('x'); return o; });
T('events-args', () => { const e = new events.EventEmitter(); let got = null; e.on('x', (...a) => got = a); e.emit('x', 1, 2); return got; });
T('events-removeAll', () => { const e = new events.EventEmitter(); e.on('x', () => { }); e.removeAllListeners('x'); return e.listenerCount('x'); });

const assert = require('assert');
T('assert-ok', () => { try { assert.ok(true); return 'pass'; } catch (e) { return 'THROW'; } });
T('assert-strictEqual-fail', () => { try { assert.strictEqual(1, 2); return 'no-throw'; } catch (e) { return e.constructor.name; } });
T('assert-deepStrictEqual', () => { try { assert.deepStrictEqual({ a: [1] }, { a: [1] }); return 'pass'; } catch (e) { return 'THROW'; } });
T('assert-deepStrictEqual-fail', () => { try { assert.deepStrictEqual({ a: 1 }, { a: 2 }); return 'no-throw'; } catch (e) { return 'threw'; } });
T('assert-throws', () => { try { assert.throws(() => { throw new Error('x'); }); return 'pass'; } catch (e) { return 'THROW'; } });

T('url-parts', () => { const u = new URL('https://a.b/c?d=1#e'); return [u.host, u.pathname, u.searchParams.get('d'), u.hash, u.protocol]; });
T('url-relative', () => new URL('/x', 'https://a.b/c').href);
T('urlsearchparams-keys', () => [...new URLSearchParams('a=1&b=2').keys()]);
T('urlsearchparams-append', () => { const s = new URLSearchParams(); s.append('a', '1'); s.append('a', '2'); return s.getAll('a'); });
T('urlsearchparams-toString', () => new URLSearchParams({ a: '1', b: '2' }).toString());

T('process-argv-type', () => Array.isArray(process.argv));
T('process-env-type', () => typeof process.env);
T('process-platform-type', () => typeof process.platform);

console.log(rows.join('\n'));

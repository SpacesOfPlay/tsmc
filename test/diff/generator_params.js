// A generator binds its parameters at the call, before the generator
// object exists: a default that throws, or a pattern with nothing to
// destructure, fails the call itself, and the body has not started.

const at = (f) => { try { return String(f()); } catch (e) { return e.constructor.name; } };
const log = [];

function* g1([x]) { log.push('body g1'); yield x; }
console.log('null pattern at the call:', at(() => g1(null)), '| ok:', g1([7]).next().value);

let calls = 0;
function* g2(x = (() => { throw new RangeError('default'); })()) { calls++; yield x; }
console.log('throwing default at the call:', at(() => g2()), 'body ran', calls, 'times', '| with an argument:', g2(3).next().value);

// the default runs at the call, the body at the first next()
function* g3(x = log.push('default')) { log.push('body g3'); yield x; }
const it3 = g3();
log.push('after the call');
it3.next();
console.log('order:', log.filter((s) => s !== 'body g1').join(' > '));

// class and object generator methods, and a static one
class C {
  *m({ a }) { yield a; }
  static *s([a, b] = null) { yield a + b; }
}
const o = { *m(x = C.missing.value) { yield x; } };
console.log('methods:', at(() => C.prototype.m(undefined)), at(() => C.s()), at(() => o.m()), '| ok:', new C().m({ a: 'A' }).next().value, C.s([1, 2]).next().value);

// an async generator throws at the call too; an async function rejects instead
async function* ag([x]) { yield x; }
async function af([x]) { return x; }
console.log('async generator:', at(() => ag(null)));
af(null).then(() => console.log('async function: resolved?!'), (e) => console.log('async function: rejected with', e.constructor.name));

// a fresh generator closed before it starts: throw() rethrows, return() completes,
// and the body never runs
function* g4() { log.push('body g4'); yield 1; }
const t = g4();
console.log('throw on a fresh generator:', at(() => t.throw(new Error('early'))), JSON.stringify(t.next()));
const r = g4();
console.log('return on a fresh generator:', JSON.stringify(r.return('bye')), JSON.stringify(r.next()), 'body g4 ran:', log.includes('body g4'));

// arguments and this are bound with the parameters
function* g5(a, b) { yield [arguments.length, this.tag, a, b]; }
console.log('arguments and this:', JSON.stringify(g5.call({ tag: 't' }, 1, 2, 3).next().value));

// the first next() input is discarded, later ones arrive
function* g6() { const got = yield 'first'; yield got; }
const s6 = g6();
console.log('inputs:', s6.next('ignored').value, s6.next('kept').value);

// assert: which comparisons pass, which fail, and what the failure carries.
//
// Messages are not compared. node composes an elaborate diff into them and any
// other implementation will word it differently; what a caller actually reads
// programmatically is the structured part -- name, code, operator, actual,
// expected -- so that is what is checked.

const assert = require('assert');

const out = [];

function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}

function T(label, v) { out.push(label + ' = ' + show(v)); }

// Runs fn and reports whether it threw, without its message.
function outcome(fn) {
  try { fn(); return 'pass'; } catch (e) {
    if (e && e.name === 'AssertionError') return 'fail';
    return 'THROW:' + (e && e.constructor ? e.constructor.name : String(e));
  }
}

// The structured fields of an assertion failure.
function shape(fn) {
  try { fn(); return 'no-throw'; } catch (e) {
    return [e.name, e.code, e.operator, show(e.actual), show(e.expected),
            typeof e.message === 'string' && e.message.length > 0].join('|');
  }
}

// --- truthiness -------------------------------------------------------------

T('ok-truthy', [outcome(() => assert.ok(1)), outcome(() => assert.ok('x')),
                outcome(() => assert.ok([]))].join(','));
T('ok-falsy', [outcome(() => assert.ok(0)), outcome(() => assert.ok('')),
               outcome(() => assert.ok(null)), outcome(() => assert.ok(undefined))].join(','));
T('assert-callable-directly', [outcome(() => assert(1)), outcome(() => assert(0))].join(','));
T('ok-shape', shape(() => assert.ok(false)));

// --- strict equality --------------------------------------------------------

T('strictEqual-same', [outcome(() => assert.strictEqual(1, 1)),
                       outcome(() => assert.strictEqual('a', 'a')),
                       outcome(() => assert.strictEqual(null, null))].join(','));
T('strictEqual-different', [outcome(() => assert.strictEqual(1, '1')),
                            outcome(() => assert.strictEqual(1, 2)),
                            outcome(() => assert.strictEqual({}, {}))].join(','));
// strictEqual uses SameValue, so NaN equals itself and 0 differs from -0
T('strictEqual-nan', outcome(() => assert.strictEqual(NaN, NaN)));
T('strictEqual-negzero', outcome(() => assert.strictEqual(0, -0)));
T('strictEqual-shape', shape(() => assert.strictEqual(1, 2)));
T('notStrictEqual', [outcome(() => assert.notStrictEqual(1, 2)),
                     outcome(() => assert.notStrictEqual(1, 1))].join(','));

// --- loose equality ---------------------------------------------------------

T('equal-loose', [outcome(() => assert.equal(1, '1')),
                  outcome(() => assert.equal(null, undefined)),
                  outcome(() => assert.equal(1, 2))].join(','));
T('notEqual', [outcome(() => assert.notEqual(1, 2)), outcome(() => assert.notEqual(1, '1'))].join(','));

// --- deep equality ----------------------------------------------------------

const D = (a, b) => outcome(() => assert.deepStrictEqual(a, b));

T('deep-objects', [D({ a: 1 }, { a: 1 }), D({ a: 1 }, { a: 2 }), D({ a: 1 }, { a: 1, b: 2 })].join(','));
T('deep-nested', [D({ a: { b: [1, 2] } }, { a: { b: [1, 2] } }),
                  D({ a: { b: [1, 2] } }, { a: { b: [1, 3] } })].join(','));
T('deep-arrays', [D([1, 2], [1, 2]), D([1, 2], [2, 1]), D([1], [1, undefined])].join(','));
T('deep-type-strict', [D(1, '1'), D({ a: 1 }, { a: '1' })].join(','));
T('deep-nan', D(NaN, NaN));
T('deep-negzero', D(0, -0));
T('deep-dates', [D(new Date(0), new Date(0)), D(new Date(0), new Date(1))].join(','));
T('deep-regexp', [D(/a/g, /a/g), D(/a/g, /a/i), D(/a/, /b/)].join(','));
T('deep-maps', [D(new Map([['k', 1]]), new Map([['k', 1]])),
                D(new Map([['k', 1]]), new Map([['k', 2]])),
                D(new Map([['k', 1]]), new Map())].join(','));
T('deep-sets', [D(new Set([1, 2]), new Set([1, 2])), D(new Set([1]), new Set([2]))].join(','));
T('deep-typedarrays', [D(new Uint8Array([1, 2]), new Uint8Array([1, 2])),
                       D(new Uint8Array([1, 2]), new Uint8Array([1, 3]))].join(','));
T('deep-prototypes-differ', (() => {
  class A { constructor() { this.x = 1; } }
  class B { constructor() { this.x = 1; } }
  return D(new A(), new B());
})());
T('deep-circular', (() => {
  const a = { n: 1 }; a.self = a;
  const b = { n: 1 }; b.self = b;
  return D(a, b);
})());
T('deep-loose', [outcome(() => assert.deepEqual({ a: 1 }, { a: '1' })),
                 outcome(() => assert.deepEqual({ a: 1 }, { a: 2 }))].join(','));
T('notDeepStrictEqual', [outcome(() => assert.notDeepStrictEqual({ a: 1 }, { a: 2 })),
                         outcome(() => assert.notDeepStrictEqual({ a: 1 }, { a: 1 }))].join(','));
T('deep-shape', shape(() => assert.deepStrictEqual({ a: 1 }, { a: 2 })));

// --- throws -----------------------------------------------------------------

T('throws-any', [outcome(() => assert.throws(() => { throw new Error('x'); })),
                 outcome(() => assert.throws(() => {}))].join(','));
T('throws-constructor', [
  outcome(() => assert.throws(() => { throw new TypeError('x'); }, TypeError)),
  outcome(() => assert.throws(() => { throw new RangeError('x'); }, TypeError)),
].join(','));
T('throws-regexp', [
  outcome(() => assert.throws(() => { throw new Error('boom happened'); }, /boom/)),
  outcome(() => assert.throws(() => { throw new Error('quiet'); }, /boom/)),
].join(','));
T('throws-predicate', [
  outcome(() => assert.throws(() => { throw new Error('x'); }, (e) => e.message === 'x')),
  outcome(() => assert.throws(() => { throw new Error('y'); }, (e) => e.message === 'x')),
].join(','));
T('doesNotThrow', [outcome(() => assert.doesNotThrow(() => {})),
                   outcome(() => assert.doesNotThrow(() => { throw new Error('x'); }))].join(','));

// --- other helpers ----------------------------------------------------------

T('fail', outcome(() => assert.fail('nope')));
T('ifError', [outcome(() => assert.ifError(null)), outcome(() => assert.ifError(undefined)),
              outcome(() => assert.ifError(new Error('x')))].join(','));
T('match', typeof assert.match === 'function'
  ? [outcome(() => assert.match('hello', /ell/)), outcome(() => assert.match('hello', /zzz/))].join(',')
  : 'missing');
T('doesNotMatch', typeof assert.doesNotMatch === 'function'
  ? [outcome(() => assert.doesNotMatch('hello', /zzz/)),
     outcome(() => assert.doesNotMatch('hello', /ell/))].join(',')
  : 'missing');
T('strict-namespace', typeof assert.strict);
T('strict-is-strict', typeof assert.strict === 'function' || typeof assert.strict === 'object'
  ? [outcome(() => assert.strict.strictEqual(1, 1)), outcome(() => assert.strict.equal(1, '1'))].join(',')
  : 'missing');
T('AssertionError-ctor', typeof assert.AssertionError);
// A supplied message leads the report. node then appends its own diff, so the
// contract worth checking is that the caller's words come first and survive.
T('custom-message-kept', (() => {
  try { assert.strictEqual(1, 2, 'my own words'); return 'no-throw'; }
  catch (e) { return [e.message.startsWith('my own words'), e.message.length > 0].join(','); }
})());
T('error-instanceof-Error', (() => {
  try { assert.ok(false); return 'no-throw'; }
  catch (e) { return [e instanceof Error, e.name].join(','); }
})());

// --- async ------------------------------------------------------------------

async function asyncChecks() {
  const rejects = typeof assert.rejects === 'function';
  if (!rejects) { out.push('rejects = "missing"'); return; }
  const r = [];
  try { await assert.rejects(async () => { throw new Error('x'); }); r.push('pass'); }
  catch (e) { r.push('fail'); }
  try { await assert.rejects(async () => 'fine'); r.push('pass'); }
  catch (e) { r.push('fail'); }
  try { await assert.rejects(async () => { throw new TypeError('x'); }, TypeError); r.push('pass'); }
  catch (e) { r.push('fail'); }
  // a rejection that does not match the expectation is a failed assertion,
  // not the original error travelling onwards
  try { await assert.rejects(async () => { throw new RangeError('x'); }, TypeError); r.push('pass'); }
  catch (e) { r.push(e.name === 'AssertionError' ? 'fail' : 'THROW:' + e.constructor.name); }
  out.push('rejects = ' + JSON.stringify(r.join(',')));
  const d = [];
  if (typeof assert.doesNotReject === 'function') {
    try { await assert.doesNotReject(async () => 'fine'); d.push('pass'); }
    catch (e) { d.push('fail'); }
    try { await assert.doesNotReject(async () => { throw new Error('x'); }); d.push('pass'); }
    catch (e) { d.push('fail'); }
    out.push('doesNotReject = ' + JSON.stringify(d.join(',')));
  } else {
    out.push('doesNotReject = "missing"');
  }
}

asyncChecks().then(() => console.log(out.join('\n')));

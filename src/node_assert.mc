// node_assert.mc -- the `assert` built-in module implementation.
//
// Embedded JS source, compiled+run once when `assert` is first
// required/imported (it requires 'util' for isDeepStrictEqual). See
// doc/PLAN_M25_assert.md.

str node_assert_source() {
    return
        "'use strict';
"
        "const { isDeepStrictEqual } = require('util');
"
        "
"
        "class AssertionError extends Error {
"
        "  constructor(opts) {
"
        "    opts = opts || {};
"
        "    super(opts.message || 'Assertion failed');
"
        "    this.name = 'AssertionError';
"
        "    this.code = 'ERR_ASSERTION';
"
        "    this.actual = opts.actual;
"
        "    this.expected = opts.expected;
"
        "    this.operator = opts.operator;
"
        "    this.generatedMessage = !opts.message;
"
        "  }
"
        "}
"
        "
"
        "function fail(message) {
"
        "  if (message instanceof Error) throw message;
"
        "  throw new AssertionError({ message: message === undefined ? 'Failed' : message, operator: 'fail' });
"
        "}
"
        "
"
        "function ok(value, message) {
"
        "  if (!value) throw new AssertionError({ message: message, actual: value, expected: true, operator: '==' });
"
        "}
"
        "
"
        "function equal(actual, expected, message) {
"
        "  if (actual != expected) throw new AssertionError({ message: message, actual: actual, expected: expected, operator: '==' });
"
        "}
"
        "function notEqual(actual, expected, message) {
"
        "  if (actual == expected) throw new AssertionError({ message: message, actual: actual, expected: expected, operator: '!=' });
"
        "}
"
        "function strictEqual(actual, expected, message) {
"
        "  if (!Object.is(actual, expected)) throw new AssertionError({ message: message, actual: actual, expected: expected, operator: 'strictEqual' });
"
        "}
"
        "function notStrictEqual(actual, expected, message) {
"
        "  if (Object.is(actual, expected)) throw new AssertionError({ message: message, actual: actual, expected: expected, operator: 'notStrictEqual' });
"
        "}
"
        "
"
        "function looseDeepEqual(a, b) {
"
        "  if (a == b) return true;
"
        "  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) return a == b;
"
        "  if (Array.isArray(a) !== Array.isArray(b)) return false;
"
        "  const ka = Object.keys(a);
"
        "  const kb = Object.keys(b);
"
        "  if (ka.length !== kb.length) return false;
"
        "  for (const k of ka) { if (!looseDeepEqual(a[k], b[k])) return false; }
"
        "  return true;
"
        "}
"
        "function deepEqual(actual, expected, message) {
"
        "  if (!looseDeepEqual(actual, expected)) throw new AssertionError({ message: message, actual: actual, expected: expected, operator: 'deepEqual' });
"
        "}
"
        "function notDeepEqual(actual, expected, message) {
"
        "  if (looseDeepEqual(actual, expected)) throw new AssertionError({ message: message, actual: actual, expected: expected, operator: 'notDeepEqual' });
"
        "}
"
        "function deepStrictEqual(actual, expected, message) {
"
        "  if (!isDeepStrictEqual(actual, expected)) throw new AssertionError({ message: message, actual: actual, expected: expected, operator: 'deepStrictEqual' });
"
        "}
"
        "function notDeepStrictEqual(actual, expected, message) {
"
        "  if (isDeepStrictEqual(actual, expected)) throw new AssertionError({ message: message, actual: actual, expected: expected, operator: 'notDeepStrictEqual' });
"
        "}
"
        "
"
        "function match(string, regexp, message) {
"
        "  if (typeof string !== 'string') throw new AssertionError({ message: 'The \"string\" argument must be of type string', operator: 'match' });
"
        "  if (!regexp.test(string)) throw new AssertionError({ message: message, actual: string, expected: regexp, operator: 'match' });
"
        "}
"
        "function doesNotMatch(string, regexp, message) {
"
        "  if (typeof string === 'string' && regexp.test(string)) throw new AssertionError({ message: message, actual: string, expected: regexp, operator: 'doesNotMatch' });
"
        "}
"
        "
"
        "function isErrorConstructor(fn) {
"
        "  if (fn === Error) return true;
"
        "  const p = fn.prototype;
"
        "  return p != null && p instanceof Error;
"
        "}
"
        "function checkError(err, expected) {
"
        "  if (expected === undefined) return true;
"
        "  if (typeof expected === 'function') {
"
        "    if (isErrorConstructor(expected)) return err instanceof expected;
"
        "    return !!expected(err);
"
        "  }
"
        "  if (expected instanceof RegExp) return expected.test(String(err));
"
        "  if (expected !== null && typeof expected === 'object') {
"
        "    for (const key of Object.keys(expected)) {
"
        "      if (expected[key] instanceof RegExp) { if (!expected[key].test(String(err[key]))) return false; }
"
        "      else if (!isDeepStrictEqual(err[key], expected[key])) return false;
"
        "    }
"
        "    return true;
"
        "  }
"
        "  return false;
"
        "}
"
        "function throws(fn, expected, message) {
"
        "  if (typeof expected === 'string') { message = expected; expected = undefined; }
"
        "  let threw = false;
"
        "  let error;
"
        "  try { fn(); } catch (e) { threw = true; error = e; }
"
        "  if (!threw) throw new AssertionError({ message: message || 'Missing expected exception.', operator: 'throws' });
"
        "  if (!checkError(error, expected)) throw error;
"
        "}
"
        "function doesNotThrow(fn, expected, message) {
"
        "  if (typeof expected === 'string') { message = expected; expected = undefined; }
"
        "  try { fn(); } catch (e) {
"
        "    throw new AssertionError({ message: message || 'Got unwanted exception.', actual: e, operator: 'doesNotThrow' });
"
        "  }
"
        "}
"
        "function ifError(value) {
"
        "  if (value !== null && value !== undefined) {
"
        "    throw new AssertionError({ message: 'ifError got unwanted exception: ' + (value && value.message !== undefined ? value.message : value), actual: value, operator: 'ifError' });
"
        "  }
"
        "}
"
        "async function rejects(promiseOrFn, expected, message) {
"
        "  if (typeof expected === 'string') { message = expected; expected = undefined; }
"
        "  const p = typeof promiseOrFn === 'function' ? promiseOrFn() : promiseOrFn;
"
        "  let threw = false;
"
        "  let error;
"
        "  try { await p; } catch (e) { threw = true; error = e; }
"
        "  if (!threw) throw new AssertionError({ message: message || 'Missing expected rejection.', operator: 'rejects' });
"
        "  if (!checkError(error, expected)) throw error;
"
        "}
"
        "async function doesNotReject(promiseOrFn, expected, message) {
"
        "  if (typeof expected === 'string') { message = expected; expected = undefined; }
"
        "  const p = typeof promiseOrFn === 'function' ? promiseOrFn() : promiseOrFn;
"
        "  try { await p; } catch (e) {
"
        "    throw new AssertionError({ message: message || 'Got unwanted rejection.', actual: e, operator: 'doesNotReject' });
"
        "  }
"
        "}
"
        "
"
        "function assert(value, message) { ok(value, message); }
"
        "assert.ok = ok;
"
        "assert.equal = equal;
"
        "assert.notEqual = notEqual;
"
        "assert.strictEqual = strictEqual;
"
        "assert.notStrictEqual = notStrictEqual;
"
        "assert.deepEqual = deepEqual;
"
        "assert.notDeepEqual = notDeepEqual;
"
        "assert.deepStrictEqual = deepStrictEqual;
"
        "assert.notDeepStrictEqual = notDeepStrictEqual;
"
        "assert.throws = throws;
"
        "assert.doesNotThrow = doesNotThrow;
"
        "assert.rejects = rejects;
"
        "assert.doesNotReject = doesNotReject;
"
        "assert.match = match;
"
        "assert.doesNotMatch = doesNotMatch;
"
        "assert.fail = fail;
"
        "assert.ifError = ifError;
"
        "assert.AssertionError = AssertionError;
"
        "
"
        "function makeStrict() {
"
        "  function s(value, message) { ok(value, message); }
"
        "  s.ok = ok;
"
        "  s.equal = strictEqual;
"
        "  s.notEqual = notStrictEqual;
"
        "  s.strictEqual = strictEqual;
"
        "  s.notStrictEqual = notStrictEqual;
"
        "  s.deepEqual = deepStrictEqual;
"
        "  s.notDeepEqual = notDeepStrictEqual;
"
        "  s.deepStrictEqual = deepStrictEqual;
"
        "  s.notDeepStrictEqual = notDeepStrictEqual;
"
        "  s.throws = throws;
"
        "  s.doesNotThrow = doesNotThrow;
"
        "  s.rejects = rejects;
"
        "  s.doesNotReject = doesNotReject;
"
        "  s.match = match;
"
        "  s.doesNotMatch = doesNotMatch;
"
        "  s.fail = fail;
"
        "  s.ifError = ifError;
"
        "  s.AssertionError = AssertionError;
"
        "  return s;
"
        "}
"
        "const strict = makeStrict();
"
        "strict.strict = strict;
"
        "assert.strict = strict;
"
        "
"
        "module.exports = assert;
"
        "
"
        ;
}

// assert: pass/throw behavior + error code (messages are elaborate and
// not compared). require('assert') works in Node CJS and tsmc alike.
const assert = require("assert");

function tc(fn) { try { fn(); return "ok"; } catch (e) { return "throw:" + (e.code || e.name); } }

console.log(tc(() => assert.ok(1)), tc(() => assert.ok(0)), tc(() => assert(true)), tc(() => assert(false)));
console.log(tc(() => assert.equal(1, "1")), tc(() => assert.equal(1, 2)));
console.log(tc(() => assert.notEqual(1, 2)), tc(() => assert.notEqual(1, 1)));
console.log(tc(() => assert.strictEqual(1, 1)), tc(() => assert.strictEqual(1, "1")));
console.log(tc(() => assert.notStrictEqual(1, "1")), tc(() => assert.notStrictEqual(1, 1)));
console.log(tc(() => assert.deepStrictEqual({ a: [1, 2] }, { a: [1, 2] })), tc(() => assert.deepStrictEqual({ a: 1 }, { a: 2 })));
console.log(tc(() => assert.deepEqual({ a: 1 }, { a: "1" })), tc(() => assert.notDeepStrictEqual({ a: 1 }, { a: 2 })));

// throws matchers
console.log(tc(() => assert.throws(() => { throw new TypeError("x"); }, TypeError)));
console.log(tc(() => assert.throws(() => { throw new Error("boom"); }, /boom/)));
console.log(tc(() => assert.throws(() => { throw new Error("z"); }, (e) => e.message === "z")));
console.log(tc(() => assert.throws(() => 1)));
console.log(tc(() => assert.doesNotThrow(() => 1)), tc(() => assert.doesNotThrow(() => { throw new Error("y"); })));

// match / ifError / fail
console.log(tc(() => assert.match("hello", /ell/)), tc(() => assert.match("hello", /xyz/)));
console.log(tc(() => assert.doesNotMatch("hello", /xyz/)), tc(() => assert.ifError(null)), tc(() => assert.ifError(new Error("e"))));
console.log(tc(() => assert.fail("nope")));

// assert.strict: loose methods become strict
console.log(tc(() => assert.strict.equal(1, "1")), tc(() => assert.strict.equal(1, 1)));
console.log(tc(() => assert.strict.deepEqual({ a: 1 }, { a: "1" })));
console.log(assert.AssertionError.name, typeof assert.strict.strict, assert.strict.strict === assert.strict);

// async rejects / doesNotReject
assert.rejects(Promise.reject(new Error("r"))).then(() => console.log("rejects: ok"));
assert.rejects(Promise.resolve(1)).then(() => console.log("rejects: FAIL")).catch((e) => console.log("rejects-noreject:", e.code));
assert.doesNotReject(Promise.resolve(1)).then(() => console.log("doesNotReject: ok"));

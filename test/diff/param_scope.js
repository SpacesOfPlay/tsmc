// Parameters bind left to right. In a list with a default, a pattern or a
// rest element, a default that reads itself or a later parameter throws a
// ReferenceError; an earlier one reads fine, and a closure made in a
// default sees a later parameter once it is bound.

const at = (f) => { try { return String(f()); } catch (e) { return e.constructor.name; } };

function later(x = y, y) { return x + ':' + y; }
console.log('later:', at(() => later()), at(() => later(undefined, 2)), at(() => later(1, 2)));

function self(x = x) { return x; }
console.log('self:', at(() => self()), at(() => self(5)));

function earlier(a, b = a + 1, c = b * 2) { return [a, b, c].join(','); }
console.log('earlier:', earlier(1), earlier(1, 5), earlier(1, undefined, 9));

function closure(a = () => b, b = 7) { return a(); }
console.log('closure over a later parameter:', closure(), closure(() => 'given'), closure(undefined, 8));

function ownClosure(a = () => a) { return a() === a; }
console.log('closure over itself:', ownClosure());

function pattern(a = q, { q } = { q: 1 }) { return a + q; }
console.log('pattern name later:', at(() => pattern()), at(() => pattern(2)), at(() => pattern(2, { q: 3 })));

function patternEarlier({ q } = { q: 4 }, a = q) { return a; }
console.log('pattern name earlier:', patternEarlier(), patternEarlier(undefined, 9));

function rest(a = more.length, ...more) { return a; }
console.log('rest later:', at(() => rest()), at(() => rest(undefined, 1, 2)), at(() => rest(3, 4, 5)));

function* gen(x = y, y) { yield x; }
console.log('generator at the call:', at(() => gen()), at(() => gen(1, 2).next().value));

function shadowVar(a = 1) { var a; return a; }
console.log('var shares the parameter:', shadowVar(), shadowVar(2));

function nested(a = 1, b = (() => { function inner(p = a, q = p) { return p + q; } return inner(); })()) { return b; }
console.log('nested function defaults:', nested());

function simple(a, b) { return a === undefined ? 'no a' : a + b; }
console.log('simple list untouched:', simple(), simple(1, 2), simple.length);

console.log('lengths:', later.length, earlier.length, rest.length, pattern.length);

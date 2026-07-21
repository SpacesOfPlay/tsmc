// The `arguments` object in ordinary functions. Every line is deterministic
// and compared byte-for-byte against Node.

// length, indexing, and surplus args beyond the declared params
function f(a, b) { return arguments.length + ' ' + arguments[0] + ' ' + arguments[2]; }
console.log(f(10, 20, 30, 40));
console.log(f(1));                      // missing args -> undefined

// fewer args than params
function g(a, b, c) { return arguments.length; }
console.log(g(1, 2));

// iteration: spread and for-of and Array.from
function collect() {
  let out = [];
  for (const x of arguments) out.push(x);
  return out.join(',');
}
console.log(collect('a', 'b', 'c'));
console.log([...(function () { return arguments; })(7, 8, 9)].join('-'));
console.log(Array.from((function () { return arguments; })(1, 2)).join('+'));

// arrows have no own arguments — they read the enclosing function's
function outer() {
  const arrow = () => arguments[0] + '/' + arguments.length;
  return arrow();
}
console.log(outer('x', 'y', 'z'));

// nested ordinary function gets its OWN arguments
function nest() {
  function inner() { return arguments.length; }
  return inner(1, 2) + ':' + arguments.length;
}
console.log(nest('a'));

// it is array-like, not an Array
const A = (function () { return arguments; })(1, 2, 3);
console.log(Array.isArray(A), A instanceof Array, typeof A.map);
console.log(Object.keys(A).join(','));          // indices only; length is non-enumerable
console.log('length' in A, A.hasOwnProperty('length'));

// unmapped (strict): writing arguments[i] does not alias the named param.
// tsmc is always unmapped; Node maps in sloppy mode, so pin this in strict
// mode where both agree.
function unmapped(x) { 'use strict'; arguments[0] = 99; return x + ' ' + arguments[0]; }
console.log(unmapped(1));

// a parameter named `arguments` shadows the object
function shadowed(arguments) { return arguments; }
console.log(shadowed(42));

// typeof inside a function is 'object'
function hasArgs() { return typeof arguments; }
console.log(hasArgs());

// call-shape coverage: apply / call / bind forward the real arguments
function shape() { return arguments.length + ':' + arguments[1]; }
console.log(shape.apply(null, [10, 20, 30]));   // 3:20
console.log(shape.call(null, 7, 8));            // 2:8
console.log(shape.bind(null, 1)(2, 3));         // 3:2

// generators and async functions have their own arguments
function* gen() { yield arguments.length; yield arguments[2]; }
const it = gen('a', 'b', 'c', 'd');
console.log(it.next().value, it.next().value);  // 4 c

async function af() { return arguments.length + '/' + arguments[0]; }
af(5, 6, 7).then((v) => console.log('async', v));   // async 3/5

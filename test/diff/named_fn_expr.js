// Named function expressions bind their own name inside the body (for
// recursion), read-only, without leaking to the enclosing scope. Compared
// byte-for-byte against Node.

// recursion via the expression's own name
const fact = function f(n) { return n <= 1 ? 1 : n * f(n - 1); };
console.log(fact(5));                       // 120

// the name does not leak to the enclosing scope
console.log(typeof f);                      // undefined

// each closure instance recurses on itself
function make() { return function rec(n) { return n <= 0 ? 'done' : rec(n - 1); }; }
console.log(make()(3));                      // done

// a parameter shadows the function-expression name
const g = function h(h) { return h; };
console.log(g(42));                          // 42

// declarations are unchanged: the name is the enclosing (reassignable) binding
function d(n) { return n <= 1 ? 1 : n * d(n - 1); }
console.log(d(5));                           // 120

// arrow inside a named function expression captures the name lexically
const outer = function self(n) {
  const step = () => (n <= 0 ? 0 : 1 + self(n - 1));
  return step();
};
console.log(outer(4));                       // 4

// named function expression as an IIFE
console.log((function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); })(10));  // 55

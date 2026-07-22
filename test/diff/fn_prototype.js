// A function object has its own [[Prototype]] that Object.setPrototypeOf can
// point at a plain object, so a function can inherit data properties, getters
// (with the function as the getter's `this`), and answer `in` against that
// chain. This is how chalk builds its styled-function chain. Compared
// byte-for-byte against Node.

// data property inherited via a function's set prototype
function f1() {}
Object.setPrototypeOf(f1, { data: 42, tag: 'x' });
console.log('data:', f1.data, f1.tag);
console.log('getProto has data:', Object.getPrototypeOf(f1).data);

// inherited getter, invoked with the function as `this`, memoizing onto it
function f2() {}
const proto = {
  get styled() {
    const builder = () => 'B:' + this.name;
    Object.defineProperty(this, 'styled', { value: builder });
    return builder;
  }
};
Object.setPrototypeOf(f2, proto);
console.log('getter:', f2.styled(), 'cached:', f2.styled === f2.styled);

// a getter-bearing function used as another function's prototype (chalk shape)
const styleProto = Object.defineProperties(() => {}, {
  red: { get() { return () => 'RED'; }, configurable: true },
  bold: { get() { return () => 'BOLD'; }, configurable: true }
});
function builder() {}
Object.setPrototypeOf(builder, styleProto);
console.log('chained:', builder.red(), builder.bold());
console.log('desc present:', typeof Object.getOwnPropertyDescriptor(styleProto, 'red'));

// the `in` operator against a function and its prototype chain
function f3() {}
f3.own = 1;
Object.setPrototypeOf(f3, { inherited: 2 });
console.log('in:', 'own' in f3, 'inherited' in f3, 'call' in f3, 'prototype' in f3, 'nope' in f3);

// null [[Prototype]] on a function: nothing inherited, not even Function.proto
function f4() {}
Object.setPrototypeOf(f4, null);
console.log('null proto:', Object.getPrototypeOf(f4), 'call' in f4);

// A class field initializer runs inside the (possibly synthesized)
// constructor, so any binding it closes over from an enclosing scope must be
// captured like a method body would capture it. A field referencing only an
// outer function or const — with no explicit constructor — used to read an
// uncaptured slot (garbage / crash). Compared byte-for-byte against Node.

const TOP_CONST = 42;
function topFn() { return 'T'; }

// field reads an outer const, default constructor
class A { x = TOP_CONST; }
console.log('const field:', new A().x);

// field calls an outer function, default constructor
class B { y = topFn(); z = topFn() + '!'; }
const b = new B();
console.log('fn-call fields:', b.y, b.z);

// field captures an outer local through a nested class (function scope)
function make() {
  const local = 7;
  const factor = 3;
  class C { v = local * factor; }
  return new C().v;
}
console.log('outer local:', make());

// field initializer that calls a private method which reads a private field
class D {
  #base = 10;
  #compute() { return this.#base * 2; }
  result = this.#compute() + TOP_CONST;
}
console.log('private+outer:', new D().result);

// arrow in a field closing over both the instance and an outer binding
class E {
  n = 5;
  get = () => this.n + TOP_CONST;
}
console.log('field arrow:', new E().get());

// interleaved outer-capturing fields and literal fields
class F {
  a = topFn();
  b = 1;
  c = TOP_CONST;
  d = 2;
}
const f = new F();
console.log('interleaved:', f.a, f.b, f.c, f.d);

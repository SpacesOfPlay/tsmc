// Private class fields and methods.

class Counter {
  #n = 0;
  #step;
  constructor(step = 1) {
    this.#step = step;
  }
  tick() {
    this.#n += this.#step;
    return this;
  }
  get value() {
    return this.#n;
  }
  #double() {
    return this.#n * 2;
  }
  doubled() {
    return this.#double();
  }
}
const c = new Counter(2);
c.tick().tick().tick();
console.log(c.value, c.doubled());

// private fields are not enumerable / not own string keys
console.log(Object.keys(c).length, JSON.stringify(c));
const seen = [];
for (const k in c) seen.push(k);
console.log(seen.length);

// increment / read / write forms
class Box {
  #v = 10;
  inc() {
    this.#v++;
    return this.#v;
  }
  add(x) {
    this.#v += x;
    return this.#v;
  }
  set(x) {
    this.#v = x;
    return this.#v;
  }
}
const b = new Box();
console.log(b.inc(), b.add(5), b.set(100));

// private field holding a reference type
class Stack {
  #items = [];
  push(x) {
    this.#items.push(x);
    return this;
  }
  pop() {
    return this.#items.pop();
  }
  get size() {
    return this.#items.length;
  }
}
const s = new Stack();
s.push(1).push(2).push(3);
console.log(s.size, s.pop(), s.size);

// static private
class Registry {
  static #count = 0;
  static register() {
    return ++Registry.#count;
  }
}
console.log(Registry.register(), Registry.register(), Registry.register());

// inheritance: subclass reads its own and (via method) the base's field
class Base {
  #kind = "base";
  #secret = 7;
  baseKind() {
    return this.#kind;
  }
  reveal() {
    return this.#secret;
  }
}
class Derived extends Base {
  #label = "derived";
  label() {
    return this.#label;
  }
}
const d = new Derived();
console.log(d.baseKind(), d.label(), d.reveal());

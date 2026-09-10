'use strict';
// A class fixes its `prototype` on the constructor: not writable, not
// enumerable, not configurable. So a store is refused, a delete is refused,
// and a static field that lands on that name cannot be defined.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

class C {}
T('descriptor', () => JSON.stringify(Object.getOwnPropertyDescriptor(C, 'prototype')));
T('store', () => { class D {} D.prototype = 1; return typeof D.prototype; });
T('delete', () => { class D {} return delete D.prototype; });
T('defineProperty over it', () => { class D {} Object.defineProperty(D, 'prototype', { value: 1 }); return 'defined'; });
T('defineProperty with the same value', () => {
  class D {}
  Object.defineProperty(D, 'prototype', { value: D.prototype });
  return 'defined';
});

// a static field cannot take that name, however it is spelled
T('static prototype field', () => { class D { static ['prototype'] = 42; } return 'defined'; });
T('static prototype field, no initializer', () => { class D { static ['prototype']; } return 'defined'; });
T('static prototype through a variable', () => { const k = 'prototype'; class D { static [k] = 1; } return 'defined'; });
T('an instance field may', () => { class D { ['prototype'] = 1; } return new D().prototype; });

// the rest of the class object is unchanged
T('a method', () => { class D { m() {} } return JSON.stringify(Object.getOwnPropertyDescriptor(D.prototype, 'm')); });
T('a static method', () => { class D { static s() {} } return JSON.stringify(Object.getOwnPropertyDescriptor(D, 's')); });
T('the constructor back-link', () => JSON.stringify(Object.getOwnPropertyDescriptor(C.prototype, 'constructor')));
T('the prototype chain', () => { class A {} class B extends A {} return Object.getPrototypeOf(B.prototype) === A.prototype; });
T('a static field', () => { class D { static f = 1; } return JSON.stringify(Object.getOwnPropertyDescriptor(D, 'f')); });
T('name and length', () => JSON.stringify([
  Object.getOwnPropertyDescriptor(C, 'name'),
  Object.getOwnPropertyDescriptor(C, 'length'),
]));

// an ordinary function's prototype is writable, a class's is not
T('a function may be reassigned', () => { function f() {} f.prototype = { tag: 1 }; return f.prototype.tag; });
T('a read-only property of a function', () => {
  function f() {}
  Object.defineProperty(f, 'ro', { value: 1 });
  f.ro = 2;
  return f.ro;
});
T('a writable one still takes it', () => {
  function f() {}
  Object.defineProperty(f, 'rw', { value: 1, writable: true });
  f.rw = 2;
  return f.rw;
});

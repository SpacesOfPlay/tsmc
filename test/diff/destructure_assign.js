// Destructuring assignment corners: null and undefined refuse even an
// empty pattern, a rest property of a string collects its characters, `in`
// is an operator again inside a pattern in a for head, and a function's
// name and length behave as the non-writable, configurable properties they
// are.

const at = (f) => { try { return String(f()); } catch (e) { return e.constructor.name; } };

console.log('empty pattern on null:', at(() => { ({} = null); return 'no throw'; }), at(() => { ({} = undefined); return 'no throw'; }), at(() => { var {} = null; return 'no throw'; }));
console.log('empty pattern on a primitive:', at(() => { ({} = 0); return 'ok'; }), at(() => { [] = 'ab'; return 'ok'; }));

let rest;
({ ...rest } = 'foo');
console.log('rest of a string:', JSON.stringify(rest), rest instanceof Object);
({ ...rest } = 42);
console.log('rest of a number:', JSON.stringify(rest));

let prop, elem;
for ({ prop = 'x' in {} } of [{}]) {}
for ([elem = 'length' in []] of [[]]) {}
console.log('in inside a for-head initializer:', prop, elem);
let paren;
for (paren = ('a' in { a: 1 }); false;) {}
console.log('in inside parentheses in a for head:', paren);

function f(a, b) {}
const d = (k) => Object.getOwnPropertyDescriptor(f, k);
console.log('name descriptor:', JSON.stringify(d('name')), '| length:', JSON.stringify(d('length')));
console.log('assign in strict:', (function () { 'use strict'; try { f.name = 'z'; return 'no throw'; } catch (e) { return e.constructor.name; } })(), f.name);
console.log('delete:', delete f.name, f.hasOwnProperty('name'), delete f.length, f.hasOwnProperty('length'), f.length);
Object.defineProperty(f, 'name', { value: 'custom' });
console.log('defined afterwards:', f.name, JSON.stringify(d('name')));
const g = () => {};
console.log('arrow defaults:', g.hasOwnProperty('name'), g.hasOwnProperty('length'), g.name, g.length);

// a class field is defined, not assigned: no inherited setter runs, and a
// static field may be named `name`
const log = [];
class P { set x(v) { log.push('setter ran'); } }
class C extends P { x = 1; static name = 'Custom'; static length = 7; }
const c = new C();
console.log('field defines:', c.x, log.length, C.name, C.length, Object.getOwnPropertyDescriptor(C, 'name').writable);

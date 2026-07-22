// Reflect's receiver may be any object-like value, functions included: they
// carry their own property table and [[Prototype]]. Every Reflect entry point
// used to reject a callable outright ("called on non-object"). Reflect.ownKeys
// also reports non-enumerable own keys, unlike Object.keys.
// Compared byte-for-byte against Node.

function target() {}
target.own = 1;

// get / set / has / deleteProperty against a function
console.log('get:', Reflect.get(target, 'own'));
console.log('set:', Reflect.set(target, 'added', 2), Reflect.get(target, 'added'));
console.log('has own:', Reflect.has(target, 'own'), 'has inherited:', Reflect.has(target, 'call'));
console.log('has missing:', Reflect.has(target, 'nope'));
console.log('delete:', Reflect.deleteProperty(target, 'added'), Reflect.has(target, 'added'));

// getPrototypeOf / setPrototypeOf against a function
function f2() {}
console.log('proto is Function.prototype:', Reflect.getPrototypeOf(f2) === Function.prototype);
const base = { inherited: 'I' };
console.log('setProto:', Reflect.setPrototypeOf(f2, base));
console.log('after setProto:', Reflect.getPrototypeOf(f2) === base, f2.inherited);
console.log('has via new proto:', Reflect.has(f2, 'inherited'));

// defineProperty against a function, including an accessor
function f3() {}
console.log('defineProperty:', Reflect.defineProperty(f3, 'v', { value: 7, enumerable: true }));
console.log('value:', f3.v);
Reflect.defineProperty(f3, 'computed', { get() { return 'G:' + this.v; }, configurable: true });
console.log('accessor:', f3.computed);

// getOwnPropertyDescriptor against a function
const d = Reflect.getOwnPropertyDescriptor(f3, 'v');
console.log('descriptor:', d.value, d.enumerable);

// ownKeys reports non-enumerable own keys too (Object.keys does not)
const o = {};
Object.defineProperty(o, 'hidden', { value: 1, enumerable: false });
o.visible = 2;
console.log('ownKeys:', JSON.stringify(Reflect.ownKeys(o)));
console.log('Object.keys:', JSON.stringify(Object.keys(o)));

// a non-object receiver is still rejected
try { Reflect.get(42, 'x'); } catch (e) { console.log('primitive rejected:', e.constructor.name); }

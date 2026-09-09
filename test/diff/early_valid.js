// Programs that sit next to an early error and must still be accepted:
// the sloppy-mode allowances and the literal forms that only a pattern
// rejects.

if (true) function f1() {}
if (false) ; else function f2() {}
console.log('function declarations as if bodies, sloppy: accepted');
l1: function f3() { return 'label body, sloppy'; }
console.log(f3());

const spread = [...[1, 2],];
console.log('trailing comma after a spread in a literal:', spread.length);
let t = 0;
const spreadAssign = [...(t = [3, 4])];
console.log('spread of an assignment in a literal:', spreadAssign.join(','));

class C {
  static constructor() { return 'a static method may be named constructor'; }
  ['constructor']() { return 'a computed key is not the constructor'; }
  get #v() { return 'pair'; }
  set #v(x) { this.last = x; }
  static get #s() { return 'static pair'; }
  static set #s(x) { C.lastStatic = x; }
  read() { this.#v = 1; C.#s = 2; return [this.#v, C.#s, this.last, C.lastStatic].join(','); }
}
console.log(C.constructor(), new C().constructor(), new C().read());

function simple(a, b) { 'use strict'; return typeof this; }
console.log('use strict with simple parameters:', simple());

const arrow = (...rest) => rest.length;
console.log('rest parameter without a trailing comma:', arrow(1, 2, 3));

// sloppy code may bind eval and arguments, repeat a parameter, and repeat a
// plain function in a block
function sloppy(eval, arguments) { return eval + arguments; }
var package = 'reserved only in strict code';
function dup(a, a) { return a; }
var seen4;
{ function f4() { return 'first'; } function f4() { return 'second'; } seen4 = f4(); }
console.log(sloppy(1, 2), package, dup(1, 2), seen4);

// a var may repeat a parameter, and a simple catch parameter
function f5(a) { var a; return a; }
try { throw 1; } catch (e) { var e = 2; }
console.log('var over a parameter:', f5(3), '| var over a catch parameter:', e);

// a labelled function declaration inside a function body hoists
function f6() { l: function inner() {} return typeof inner; }
console.log('labelled declaration in a body:', f6());

// super.x in an arrow inside a derived constructor; a computed key may
// use arguments, an initializer may not
class Base { constructor() { this.tag = 'base'; } }
class Derived extends Base { constructor() { super(); const name = () => super.constructor.name; this.after = name(); } }
function mk() { return class { [arguments[0]] = 'from a computed key'; }; }
console.log(new Derived().tag, new Derived().after, new (mk('key'))().key);

// an escaped contextual keyword is an ordinary identifier, and an escaped
// reserved word is fine as a property name
var async = 'escaped async as a name';
var get = 'escaped get as a name';
console.log(async, get, ({ for: 'for' }).for, ({ get: 'get key' }).get);

// parentheses settle the operators that may not mix
console.log((-2) ** 2, (null ?? 'a') || 'b', null ?? ('a' && 'c'), (2 ** 3) ** 2, 2 ** -1);

// an optional chain may be read and called, and a template may follow a
// parenthesised chain
const oc = { b: 1, t: (s) => s.raw[0] };
console.log(oc?.b, (oc?.t)`paren`, oc?.missing?.(), typeof oc?.["b"]);

// arrows and yield with the newline on the other side
const ar1 = (a) =>
  a + 1;
const ar2 = a =>
  a + 2;
function* gen() { yield 1; yield* [2]; const v = yield
  3; return v; }
console.log(ar1(1), ar2(1), [...gen()]);

// numeric separators, one __proto__, get and set as plain keys
console.log(1_000, 0x1_0, 1_0.0_1, ({ __proto__: null, ['__proto__']: 1 }).__proto__, ({ get: 1, set: 2, async: 3 }).async);

// labels may repeat across functions and static blocks, and break may
// leave a loop inside a static block; a for-of may iterate a parenthesised
// async, and a for-await one plainly
a: { function labelled() { a: { return 'inner a'; } } console.log(labelled()); }
class S { static { a: for (const x of [1, 2]) { if (x === 2) break a; S.seen = x; } } }
console.log(S.seen);
var async = [7];
for ((async) of [[8]]) ;
console.log(async);
async function fa() { var async = 0; for await (async of [9]) ; return async; }
fa().then((v) => console.log('for await async:', v));

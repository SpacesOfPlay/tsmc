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

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

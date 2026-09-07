// A plain call in sloppy-mode code sees the global object as `this`;
// strict-mode code (a "use strict" directive, a class body) sees
// undefined. A script is sloppy unless it opts in.

const tag = (v) => (v === globalThis ? 'global' : v === undefined ? 'undefined' : typeof v);

function plain() { return tag(this); }
function strict() { 'use strict'; return tag(this); }
console.log('plain:', plain(), '| strict:', strict());

// the directive covers nested functions
function outer() {
  'use strict';
  function inner() { return tag(this); }
  return inner();
}
console.log('nested in strict:', outer());

// an arrow takes this from the enclosing function
function withArrow() { return (() => tag(this))(); }
console.log('arrow in sloppy:', withArrow());

// class bodies are strict: a detached method sees undefined
class K { m() { return tag(this); } static s() { return tag(this); } }
const m = new K().m, s = K.s;
console.log('class method:', m(), '| static:', s());

// an object-literal method in sloppy code is sloppy
const o = { m() { return tag(this); } };
const om = o.m;
console.log('object method:', om());

// callbacks: a plain callback is called with undefined, so sloppy sees global
console.log('callback:', [1].map(function () { return tag(this); })[0], '| with thisArg:', [1].map(function () { return tag(this); }, { x: 1 })[0]);

// call/apply with null or undefined
console.log('call(null):', plain.call(null), '| apply(undefined):', plain.apply(undefined), '| strict call(null):', strict.call(null));

// a real receiver is untouched either way
console.log('receiver:', plain.call({ x: 1 }), strict.call({ x: 1 }));

// the script's own top-level this is the module's exports object
console.log('top level:', tag(this), this === module.exports);

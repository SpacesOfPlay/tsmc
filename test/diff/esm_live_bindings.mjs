// Live export bindings: a store to an exported binding is visible to the
// importer, whether it happens at module level, in a nested function,
// through destructuring, a loop head or a compound assignment.

import main, * as m from './esm_live/state.mjs';
import { counter, b, a, p, q, Shape, cached } from './esm_live/state.mjs';

console.log('util:', m.util.x, m.util.double(21));
console.log('later:', m.later);

console.log('counter start:', counter, m.counter);
m.bump(); m.bump();
console.log('after two bumps:', counter);
m.add(10);
console.log('after add:', counter);
m.reset();
console.log('after reset:', counter);

console.log('aliases:', a, b);
m.setA(7);
console.log('aliases after set:', a, b, m.a, m.b);

console.log('pair:', p, q);
m.swap();
console.log('pair after swap:', p, q);

console.log('last of loop:', m.last);
console.log('from below:', m.fromBelow);

console.log('default:', main(), m.default());
m.replaceMain();
console.log('default after replace:', main(), m.default());

console.log('class:', Shape.name);
m.replaceShape();
console.log('class after replace:', Shape.name, m.Shape.name);

console.log('cached:', cached);
m.fill();
console.log('cached after fill:', cached);

console.log('keys:', Object.keys(m).sort().join(','));

import zdef, { z, answer, unassigned } from './esm_live/reexport.mjs';
import * as re from './esm_live/reexport.mjs';
console.log('namespace re-export:', z.answer, z.twice(4), zdef === z, answer);
console.log('star as:', re.grouped.answer, re.grouped === z);
console.log('unassigned var:', unassigned, 'unassigned' in re, Object.keys(re).sort().join(','));

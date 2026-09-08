// delete with a computed key on an array: a string that spells an index
// removes the element, any other key removes the named property, and a
// key that names nothing still answers true.

const hop = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const a = [10, 20, 30];
a.tag = 'named';
const idx = '1', named = 'tag', missing = 'nope';
console.log(delete a[idx], hop(a, '1'), '1' in a, a.length, JSON.stringify(a));
console.log(delete a[named], hop(a, 'tag'), a.tag);
console.log(delete a[missing], delete a['7'], a.length);
console.log(delete a[0], hop(a, '0'), JSON.stringify(a));

// the match result of a regex is an array with named properties
const m = /b(c)/d.exec('abcd');
for (const k of ['index', 'input', 'groups', 'indices']) {
  const name = k;
  console.log(k, delete m[name], hop(m, k));
}
const ind = /b(c)/d.exec('abcd').indices;
const zero = '0';
console.log(delete ind[zero], hop(ind, '0'), ind.length, JSON.stringify(ind));

// non-index numeric strings are ordinary keys
const b = [1];
b['01'] = 'padded';
b['1.5'] = 'frac';
console.log(delete b['01'], hop(b, '01'), delete b['1.5'], hop(b, '1.5'), b.length);


// a function carries properties of its own, and delete removes them in
// both forms; a class's static members are such properties
function f() {}
f.tag = 1;
f.other = 2;
const key = 'tag';
console.log('function:', delete f[key], hop(f, 'tag'), delete f.other, hop(f, 'other'), delete f.absent);
class K { static m() {} static s = 1; }
const mname = 'm';
console.log('class statics:', delete K[mname], hop(K, 'm'), typeof K.m, delete K.s, hop(K, 's'));
Object.defineProperty(f, 'fixed', { value: 1, configurable: false });
console.log('non-configurable, strict:', (function () { 'use strict'; try { delete f['fixed']; return 'no throw'; } catch (e) { return e.constructor.name; } })(), hop(f, 'fixed'));

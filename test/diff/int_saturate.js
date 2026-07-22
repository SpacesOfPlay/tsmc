// A relative index of Infinity (or a magnitude beyond the i32 range) must
// saturate, not overflow to 0 when narrowed. slice(1, Infinity) etc. once
// returned nothing because the end index wrapped to 0. This is the primitive
// ramda's tail/pipe rely on. Compared byte-for-byte against Node.

const arr = ['a', 'b', 'c', 'd'];

// Array.prototype.slice / fill / copyWithin / flat with Infinity ends
console.log(JSON.stringify(arr.slice(1, Infinity)));
console.log(JSON.stringify(arr.slice(1, 1e21)));
console.log(JSON.stringify(arr.slice(-Infinity, 3)));
console.log(JSON.stringify([1, 2, 3, 4, 5].fill(0, 2, Infinity)));
console.log(JSON.stringify([1, 2, 3, 4, 5].copyWithin(0, 3, Infinity)));
console.log(JSON.stringify([1, [2, [3, [4]]]].flat(Infinity)));

// indexOf / lastIndexOf fromIndex at the extremes
console.log([1, 2, 3, 2, 1].indexOf(2, -Infinity), [1, 2, 3, 2, 1].lastIndexOf(2, Infinity));

// splice with an Infinity delete count
const s = [1, 2, 3, 4, 5];
console.log(JSON.stringify(s.splice(1, Infinity)), JSON.stringify(s));

// String slice / substring / substr with Infinity
console.log('hello'.slice(1, Infinity), 'hello'.substring(1, Infinity), 'hello'.substr(1, Infinity));
console.log('hello'.slice(-Infinity, 3), 'hello'.substr(-2, Infinity));

// the ramda pattern: forwarding arguments through slice(1, Infinity)
function tail() { return Array.prototype.slice.call(arguments, 1, Infinity); }
console.log(JSON.stringify(tail(10, 20, 30)));

// typed arrays: slice / subarray / fill with Infinity
console.log(JSON.stringify(Array.from(new Uint8Array([1, 2, 3, 4]).slice(1, Infinity))));
console.log(JSON.stringify(Array.from(new Uint8Array([1, 2, 3, 4]).subarray(1, Infinity))));

// guardrail: a real out-of-range allocation still throws, no saturating hang
try { 'x'.repeat(Infinity); } catch (e) { console.log('repeat:', e.constructor.name); }

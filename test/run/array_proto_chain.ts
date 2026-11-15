// an object made from an array reads the array through its prototype;
// Object.assign takes a function as its target; concat takes any receiver
const base = [7, 8];
const o = Object.create(base);
console.log(o.length, o[1], "0" in o, o.slice(0).length);
const f = function () {};
Object.assign(f, { x: 1 });
console.log(f.x, [].concat.call(o, 5).length);

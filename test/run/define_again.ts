// A non-configurable property may be defined again with what it has:
// its own descriptor restated (axios's freezeMethods reads every own
// descriptor of a function and defines them all again), an accessor
// with the same getter, a half left out, a data value unchanged.
function f() {}
Object.defineProperties(f, Object.getOwnPropertyDescriptors(f));
console.log("function again", typeof f.prototype);
const o = {};
Object.defineProperty(o, "v", { value: 2, writable: false, configurable: false });
Object.defineProperty(o, "v", Object.getOwnPropertyDescriptor(o, "v"));
Object.defineProperty(o, "v", { value: 2, writable: false, configurable: false, enumerable: false });
console.log("data again", o.v);
const get = () => 1;
Object.defineProperty(o, "a", { get, configurable: false, enumerable: true });
Object.defineProperty(o, "a", { get, enumerable: true });
Object.defineProperty(o, "a", { configurable: false });
console.log("accessor again", o.a);
Object.defineProperty(o, "w", { value: 1, writable: true, configurable: false });
Object.defineProperty(o, "w", { value: 5, writable: false });
console.log("writable once", o.w);
const refused = [];
for (const [k, desc] of [["a", { get: () => 2 }], ["a", { value: 1 }], ["a", { configurable: true }], ["a", { enumerable: false }], ["v", { value: 3 }], ["v", { writable: true }], ["v", { get }], ["w", { value: 6 }]]) {
  try { Object.defineProperty(o, k, desc); refused.push("no"); } catch (e) { refused.push(e instanceof TypeError ? "TypeError" : "other"); }
}
console.log("refused", refused.join(" "));

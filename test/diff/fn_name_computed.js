// A function defined under a computed key is named by the key at run
// time, as a static key names it at compile time: methods, accessors with
// their prefix, anonymous function and class values, symbols as
// [description]. A function that already has a name keeps it.

const k = 'dyn', sym = Symbol('desc'), anon = Symbol();
const o = {
  m() {}, get g() {}, set s(v) {},
  [k]() {}, get [k + 'G']() {}, set [k + 'S'](v) {},
  [k + 'F']: function () {}, [k + 'A']: () => {}, [k + 'C']: class {},
  [sym]() {}, [anon]() {}, [Symbol.iterator]() {},
  named: function inner() {}, [k + 'N']: function inner2() {},
  get [anon]() {},
};
const d = (n) => Object.getOwnPropertyDescriptor(o, n);
console.log(o.m.name, '|', d('g').get.name, '|', d('s').set.name);
console.log(o[k].name, '|', d(k + 'G').get.name, '|', d(k + 'S').set.name);
console.log(o[k + 'F'].name, '|', o[k + 'A'].name, '|', o[k + 'C'].name);
console.log(JSON.stringify(o[sym].name), '|', JSON.stringify(o[Symbol.iterator].name), '|', JSON.stringify(d(anon).get.name));
console.log(o.named.name, '|', o[k + 'N'].name);

class C { [k]() {} static [k + 'S']() {} get [k + 'G']() {} static m() {} [sym]() {} }
console.log(new C()[k].name, '|', C[k + 'S'].name, '|', Object.getOwnPropertyDescriptor(C.prototype, k + 'G').get.name, '|', C.m.name, '|', C.prototype[sym].name);

// a function that was defined elsewhere is not renamed by a computed key
const arr = [() => {}];
const o2 = { [k]: arr[0] };
console.log(JSON.stringify(o2[k].name));

// the name is an own, non-enumerable, configurable property
console.log(Object.keys(o[k]).length, Object.getOwnPropertyDescriptor(o[k], 'name').enumerable, Object.getOwnPropertyDescriptor(o[k], 'name').configurable);

// the same literal in a loop names each closure by its own key
const fns = [];
for (const key of ['one', 'two']) fns.push({ [key]() {} }[key]);
console.log(fns.map((f) => f.name).join(','));

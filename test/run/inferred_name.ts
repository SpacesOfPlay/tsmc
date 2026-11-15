// A function or class named after its property key or binding gets only
// its .name: the name is not bound inside it, as it is for a named
// function expression. GitHub's module loader has
// `{ i: function (e) { i.K.clone += 1 } }` and means the module's i.
var o1 = { f: function () { return typeof f; } };
var o2 = { g: () => typeof g };
var o3 = { h() { return typeof h; } };
var o4 = { k: function named() { return typeof named; } };
var v = function () { return typeof v; };
let w = function () { return typeof w; };
var o5 = {}; o5.m = function () { return typeof m; };
var o6 = { n: class { who() { return typeof n; } } };
let C = class { who() { return typeof C; } };
var D = class Named { who() { return typeof Named; } };
console.log("property function", o1.f());
console.log("property arrow", o2.g());
console.log("method", o3.h());
console.log("named function expression", o4.k());
console.log("var and let", v(), w());
console.log("member assignment", o5.m());
console.log("property class", new o6.n().who());
console.log("class assignment", new C().who());
console.log("named class expression", new D().who());
console.log("names", o1.f.name, o2.g.name, o3.h.name, o6.n.name, C.name, D.name);
var i = { K: { clone: 0 } };
var mod = { i: function (e) { return i.K.clone += 1, e; } };
console.log("outer binding", mod.i(5), i.K.clone);

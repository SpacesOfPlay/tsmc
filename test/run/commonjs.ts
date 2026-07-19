// CommonJS require: whole-object exports, exports.x attach, built-in
// require, cache identity + module-local state, circular requires, and
// the missing-module error. Aux modules live in ./cjs/ (the run harness
// only globs *.ts, so they never execute standalone). Deterministic.

const math = require("./cjs/math");
console.log(math.add(2, 3), math.mul(4, 5));

const strings = require("./cjs/strings");
console.log(strings.shout("go"), strings.here, strings.self);

// cache identity + persistent module state
const c1 = require("./cjs/counter");
const c2 = require("./cjs/counter");
console.log(c1 === c2, c1.tick(), c1.tick(), c2.tick());

// circular requires: each sees the other's partial exports
const a = require("./cjs/a");
const b = require("./cjs/b");
console.log(a.name, a.bName, b.name, b.aNameAtLoad, b.aBNameMissing);
console.log(a.lateB());

// missing module + bare (node_modules) both throw
function why(f) { try { f(); return "no throw"; } catch (e) { return e.constructor.name; } }
console.log(why(() => require("./cjs/nope")), why(() => require("some-pkg")));

// built-in modules load via require too
console.log(typeof require("os").platform, typeof require("node:path").join);

import { add, mul, PI } from "./mod/math";
import { Circle, version } from "./mod/shapes";
import * as util from "./mod/util";
import def from "./mod/math";

console.log("add", add(2, 3), "mul", mul(4, 5));
console.log("pi", PI);
const c = new Circle(2);
console.log("area", c.area().toFixed(2), "version", version);
console.log(util.greeting, util.repeat("ab", 3));
console.log("default", def(42));

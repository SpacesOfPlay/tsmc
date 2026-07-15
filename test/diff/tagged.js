// Tagged template literals.

function join(strings, ...values) {
  return strings.join("|") + "#" + values.join(",");
}
console.log(join`a${1}b${2}c`);
console.log(join`${1}${2}${3}`);
console.log(join`plain`);

// cooked vs raw
function pick(strings) {
  return strings[0] + " / " + strings.raw[0];
}
console.log(pick`line\nbreak\t!`);

function rawJoin(strings) {
  return strings.raw.join("|");
}
console.log(rawJoin`a\n${1}b\t${2}c`);

// shape of the strings object
function shape(strings, ...v) {
  return [
    Array.isArray(strings),
    Array.isArray(strings.raw),
    strings.length,
    strings.raw.length,
    v.length,
  ].join(",");
}
console.log(shape`x${1}y${2}z`);

// member tag keeps its receiver as `this`
const fmt = {
  prefix: "P:",
  run(strings, ...v) {
    return this.prefix + strings.map((q, i) => q + (v[i] ?? "")).join("");
  },
};
console.log(fmt.run`hello ${"world"}!`);

// interpolation values and expressions
const name = "World";
const n = 41;
console.log(join`Hello ${name}, ${n + 1}`);

// String.raw
console.log(String.raw`a\nb${1 + 1}c\t${"x"}`);
console.log(String.raw`no subs \n here`);
const dir = "/usr";
console.log(String.raw`${dir}\bin\app`);

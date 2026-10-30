// an arrow with a parenthesised body as a default inside a destructured
// arrow parameter: the inner attempts do not spoil the outer one
const f = (({ a: x = !0, g = () => (0, 1), ...v }, h) => x);
console.log(f({}, 1));
const m = ({ p: q = () => (2) }) => q();
console.log(m({}));

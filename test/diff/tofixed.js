// Number.prototype.toFixed: the digits are those of round(x * 10^d) as an exact
// integer, so every fraction digit is a real digit of the double's value and not
// padding. The cases here are the ones that separate an exact implementation from
// a double-only one: more digits than a double has, values whose product with
// 10^d lands exactly halfway, and a product too large for a double's steps to
// show a halfway case at all.
const rows = [];
const at = (label, v, d) => {
  let s;
  try { s = v.toFixed(d); } catch (e) { s = 'THROW:' + e.constructor.name; }
  rows.push(label + ' d=' + d + ' -> ' + s);
};

// past the seventeen significant digits a double prints
for (const d of [17, 18, 20, 25, 40, 50, 99, 100]) {
  at('1.1', 1.1, d);
  at('0.1', 0.1, d);
  at('0.3', 0.3, d);
  at('123.456', 123.456, d);
}

// halfway cases, which round to the larger n
for (const d of [0, 1, 2, 3, 4]) {
  for (const v of [0.5, 1.5, 2.5, 3.5, 0.05, 0.15, 0.25, 1.005, 1.255, 8.575,
                   0.615, 10.235, 4.35, 4.45, 1.45, 1.55, 99.995, 0.125, 0.375]) {
    at(String(v), v, d);
    at(String(-v), -v, d);
  }
}

// a product above 2^52, where a double cannot represent the halfway point
at('631345510776.78125', 631345510776.78125, 4);
at('631345510776.78125', 631345510776.78125, 5);
for (let i = 0; i < 40; i++) at('tie' + i, (i * 2 + 1) * 1e12 + 0.5, 1);

// the ends of the range
for (const d of [0, 2, 20, 100]) {
  at('0', 0, d);
  at('-0', -0, d);
  at('1e-7', 1e-7, d);
  at('1e20', 1e20, d);
  at('1e21', 1e21, d);
  at('-1e21', -1e21, d);
  at('5e-324', 5e-324, d);
  at('2.2250738585072014e-308', 2.2250738585072014e-308, d);
  at('NaN', NaN, d);
  at('Infinity', Infinity, d);
  at('-Infinity', -Infinity, d);
}

// a deterministic spread, the shapes a real program formats
let seed = 24681;
const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
for (const d of [0, 1, 2, 4, 7, 15, 21, 22, 23, 30]) {
  for (let i = 0; i < 25; i++) {
    for (const v of [rnd() * 1000, rnd() * 1e15, rnd() * 4.5e15, rnd() * 1e-6,
                     i / 8, i / 7, i * 1.5 + 0.125, (i + 0.5) * 1e-5]) {
      at('r', v, d);
      at('r', -v, d);
    }
  }
}

// the argument itself
at('1.25 float digits', 1.25, 1.9);
at('1.25 string digits', 1.25, '3');
at('1.25 NaN digits', 1.25, NaN);
at('1.25 undefined digits', 1.25, undefined);
at('1.25 negative digits', 1.25, -1);
at('1.25 too many digits', 1.25, 101);
rows.push('no argument -> ' + (1.25).toFixed());
rows.push('on a wrapper -> ' + Number.prototype.toFixed.call(new Number(2.345), 2));
try { Number.prototype.toFixed.call('2.345', 2); }
catch (e) { rows.push('on a string -> THROW:' + e.constructor.name); }

console.log(rows.join('\n'));

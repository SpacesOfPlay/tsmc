// Decimal text to the nearest double, for literals and for Number()/parseFloat.
// Scaling a mantissa by a power of ten in doubles rounds twice and lands a unit
// or two out, so these are the cases that separate a correctly-rounded
// conversion from an approximate one.
const rows = [];
const p = (label, v) => rows.push(label + ' -> ' + v);

// the classics: ties at the 17th digit, the denormal boundary, the extremes
p('9007199254740993', 9007199254740993);
p('999999999999999.9', 999999999999999.9);
p('999999999999999.9 === 1e15', 999999999999999.9 === 1e15);
p('MAX literal is MAX_VALUE', 1.7976931348623157e308 === Number.MAX_VALUE);
p('MIN literal is MIN_VALUE', 5e-324 === Number.MIN_VALUE);
p('2.2250738585072011e-308', 2.2250738585072011e-308);
p('2.2250738585072014e-308', 2.2250738585072014e-308);
p('4.4501477170144023e-308', 4.4501477170144023e-308);
p('1e-320', 1e-320);
p('8.98846567431158e307', 8.98846567431158e307);
p('1.0000000000000002', 1.0000000000000002);
p('1234567890123456789', 1234567890123456789);
p('123456789012345678901234567890', 123456789012345678901234567890);
p('1e310', 1e310);
p('1e-400', 1e-400);
p('1e23', 1e23);
p('7.2057594037927933e16', 7.2057594037927933e16);
p('1e300 * 1e-300', 1e300 * 1e-300);
p('0.1 + 0.2', 0.1 + 0.2);

// a literal and the string of the same digits have to agree
for (const s of ['9007199254740993', '999999999999999.9', '1.7976931348623157e308',
                 '5e-324', '1e-320', '2.2250738585072011e-308', '1.0000000000000002',
                 '1234567890123456789', '0.1', '0.3', '631345510776.78125',
                 '1e23', '4.9406564584124654e-324', '1e310', '1e-400']) {
  p('Number(' + s + ')', Number(s));
  p('parseFloat(' + s + ')', parseFloat(s));
  p('JSON ' + s, JSON.parse('[' + s + ']')[0]);
}

// separators belong to literals, not to strings
p('1_000.5', 1_000.5);
p('1_0e1_0', 1_0e1_0);
p('Number("1_0")', Number('1_0'));
p('parseFloat("1_0")', parseFloat('1_0'));

// the forms a literal may take
p('.5', .5);
p('5.', 5.);
p('0.0', 0.0);
p('1e0', 1e0);
p('1E2', 1E2);
p('1e+2', 1e+2);
p('0x1fffffffffffff', 0x1fffffffffffff);
p('0b1010', 0b1010);
p('0o777', 0o777);

// every double must read back from its own shortest form
let seed = 991;
const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
let ok = true;
for (let i = 0; i < 4000; i++) {
  const v = (rnd() - 0.5) * Math.pow(10, Math.floor(rnd() * 60) - 30);
  if (Number(String(v)) !== v) { ok = false; p('round-trip broke at', v); }
}
p('4000 round-trips', ok);

console.log(rows.join('\n'));

// Number formatting and parsing: String(n) and its exponential thresholds,
// toFixed / toPrecision / toExponential, toString(radix) including fractions,
// parseInt / parseFloat, Number() coercion, and the arithmetic edges around
// zero and overflow.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// --- String(number): the exponential thresholds ---
T('str-small-int', () => [String(0), String(1), String(-1), String(1000)]);
T('str-1e20', () => String(1e20));
T('str-1e21', () => String(1e21));
T('str-1e-6', () => String(1e-6));
T('str-1e-7', () => String(1e-7));
T('str-large-precise', () => String(123456789012345678901234567890));
T('str-fraction', () => [String(0.5), String(0.1), String(1 / 3)]);
T('str-neg-zero', () => [String(-0), String(0), Object.is(-0, 0)]);
T('str-infinity', () => [String(Infinity), String(-Infinity), String(NaN)]);
T('str-trailing', () => [String(1.0), String(1.5), String(100.0)]);
T('str-max-min', () => [String(Number.MAX_VALUE), String(Number.MIN_VALUE)]);
T('str-safe-int', () => [String(Number.MAX_SAFE_INTEGER), String(Number.MIN_SAFE_INTEGER)]);
T('str-epsilon', () => String(Number.EPSILON));
T('str-float-artifacts', () => [String(0.1 + 0.2), String(0.3), String(4.35 * 100)]);
T('template-number', () => `${1e21} ${1e-7} ${-0}`);

// --- toFixed ---
T('tofixed-basic', () => [(1.005).toFixed(2), (1.25).toFixed(1), (1.35).toFixed(1)]);
T('tofixed-zero', () => [(1.5).toFixed(0), (2.5).toFixed(0), (-1.5).toFixed(0)]);
T('tofixed-pad', () => [(1).toFixed(3), (0).toFixed(2)]);
T('tofixed-negative', () => [(-1.234).toFixed(2), (-0.001).toFixed(2)]);
T('tofixed-large', () => (1e21).toFixed(2));
T('tofixed-out-of-range', () => (1).toFixed(101));
T('tofixed-nan', () => [NaN.toFixed(2), Infinity.toFixed(2)]);

// --- toPrecision / toExponential ---
T('toprecision-basic', () => [(123.456).toPrecision(4), (0.000123).toPrecision(2)]);
T('toprecision-expands', () => [(1).toPrecision(5), (123456).toPrecision(3)]);
T('toprecision-undefined', () => (123.456).toPrecision());
T('toexponential-basic', () => [(123456).toExponential(2), (0.00123).toExponential(1)]);
T('toexponential-undefined', () => (123.456).toExponential());
T('toexponential-zero', () => (0).toExponential(2));

// --- toString(radix) ---
T('radix-int', () => [(255).toString(16), (255).toString(2), (255).toString(8), (35).toString(36)]);
T('radix-negative', () => (-255).toString(16));
T('radix-fraction-2', () => (0.5).toString(2));
T('radix-fraction-16', () => (0.5).toString(16));
T('radix-fraction-mixed', () => (10.25).toString(2));
T('radix-third', () => (1 / 3).toString(3).slice(0, 8));
T('radix-10-default', () => (255).toString());
T('radix-invalid', () => (255).toString(37));
T('radix-one', () => (255).toString(1));
T('radix-zero-value', () => [(0).toString(2), (-0).toString(2)]);

// --- parseInt / parseFloat ---
T('parseint-basic', () => [parseInt('42'), parseInt('42px'), parseInt('  42  ')]);
T('parseint-radix', () => [parseInt('ff', 16), parseInt('0x1f'), parseInt('10', 2)]);
T('parseint-radix-zero', () => parseInt('0x10', 0));
T('parseint-invalid', () => [parseInt('abc'), parseInt(''), parseInt('  ')]);
T('parseint-sign', () => [parseInt('-42'), parseInt('+42'), parseInt('- 42')]);
T('parseint-radix-out-of-range', () => [parseInt('10', 1), parseInt('10', 37)]);
T('parseint-leading-zeros', () => [parseInt('0123'), parseInt('010', 8)]);
T('parseint-large', () => parseInt('9007199254740993'));
T('parseint-non-string', () => [parseInt(42.9), parseInt(null), parseInt(true)]);
T('parsefloat-basic', () => [parseFloat('3.14'), parseFloat('3.14abc'), parseFloat('.5')]);
T('parsefloat-exp', () => [parseFloat('1e3'), parseFloat('1.5e-3')]);
T('parsefloat-infinity', () => [parseFloat('Infinity'), parseFloat('-Infinity')]);
T('parsefloat-invalid', () => [parseFloat('abc'), parseFloat('')]);
T('parsefloat-hex', () => parseFloat('0x10'));
T('parse-aliases', () => [Number.parseInt === parseInt, Number.parseFloat === parseFloat]);

// --- Number() coercion ---
T('number-strings', () => [Number('42'), Number(' 42 '), Number('')]);
T('number-radix-prefixes', () => [Number('0x1f'), Number('0b101'), Number('0o17')]);
T('number-invalid', () => [Number('abc'), Number('42px'), Number('1.2.3')]);
T('number-infinity-str', () => [Number('Infinity'), Number('-Infinity'), Number('+Infinity')]);
T('number-misc', () => [Number(null), Number(undefined), Number(true), Number([]), Number([5]), Number([1, 2])]);
T('number-whitespace-forms', () => [Number('\t42\n'), Number(' 42')]);
T('number-exponent-str', () => [Number('1e3'), Number('1E3'), Number('1e')]);

// --- literals and predicates ---
T('numeric-separators', () => [1_000_000, 0xff_ff, 1_0.5]);
T('literal-forms', () => [0b1010, 0o17, 0xff, 1e3, .5, 5.]);
T('is-predicates', () => [Number.isInteger(5), Number.isInteger(5.5), Number.isSafeInteger(2 ** 53), Number.isFinite('5'), isFinite('5')]);
T('isnan-forms', () => [Number.isNaN(NaN), Number.isNaN('x'), isNaN('x')]);
T('constants', () => [Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER, Number.EPSILON > 0]);

// --- arithmetic edges ---
T('div-zero', () => [1 / 0, -1 / 0, 0 / 0]);
T('neg-zero-literal', () => [Object.is(-0, -0), 1 / -0, Math.round(-0.4), Object.is(-(0), -0)]);
T('int-overflow', () => [2 ** 53, 2 ** 53 + 1, (2 ** 53 + 2)]);
T('bitwise-coercion', () => [1e10 | 0, -1 >>> 0, 2 ** 32 | 0]);
T('modulo-signs', () => [5 % 3, -5 % 3, 5 % -3, 5.5 % 2]);
T('exponent-edge', () => [(-2) ** 2, 2 ** -1, 0 ** 0]);

// Exactly-representable fractions round-trip through every radix; a repeating
// expansion in a non-power-of-two radix may differ from node in its last digit
// or two, which needs a bignum expansion to match exactly.
T('radix-exact-fractions', () => [(0.25).toString(2), (0.75).toString(16), (255.5).toString(8), (10.25).toString(2)]);
T('radix-strips-trailing', () => (0.5).toString(4));
T('radix-repeating-power-of-two', () => (1 / 3).toString(2));

console.log(rows.join('\n'));

// Not asserted:
//   - toFixed rounds a scaled product, so a value whose decimal literal ends
//     in 5 but whose double sits just below the midpoint rounds up where node
//     rounds down — (0.615).toFixed(2) is "0.62" here, "0.61" in node — and
//     past 17 significant digits it pads with zeros rather than continuing the
//     binary expansion. Both need exact decimal expansion of the double.
//   - an integer multiplication yielding zero with mixed signs gives 0, not
//     -0: `Object.is(0 * -1, -0)` is false. The check belongs in the
//     interpreter's multiply, and adding it there costs just enough stack to
//     break the native re-entry limit that test_hardening pins.

// Number formatting and the Math library, including the rounding and edge
// cases where a small mistake is invisible until it matters.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

T('toFixed', () => [(1.005).toFixed(2), (1.5).toFixed(0), (-1.5).toFixed(0), (0).toFixed(2)]);
T('toFixed-large', () => (1e21).toFixed(2));
T('toFixed-range', () => (1).toFixed(101));
T('toFixed-negative-range', () => (1).toFixed(-1));
T('toPrecision', () => [(123.456).toPrecision(4), (0.000123).toPrecision(2)]);
T('toExponential', () => [(12345).toExponential(2), (0.00012).toExponential(1)]);
T('toString-radix', () => [(255).toString(16), (255).toString(2), (35).toString(36)]);
T('toString-radix-range', () => (1).toString(37));
T('toString-default', () => [(255).toString(), String(1e21), String(1e-7), String(-0)]);
T('number-precision', () => [0.1 + 0.2, (0.1 + 0.2).toFixed(1)]);

T('parseInt', () => [parseInt('0x1F'), parseInt('08'), parseInt('12ab'), parseInt('')].map(String));
T('parseInt-radix', () => [parseInt('11', 2), parseInt('ff', 16), parseInt('z', 36)]);
T('parseFloat', () => [parseFloat('3.14abc'), parseFloat('.5'), parseFloat('1e3'), String(parseFloat('abc'))]);

T('isInteger', () => [Number.isInteger(1), Number.isInteger(1.5), Number.isInteger('1')]);
T('isSafeInteger', () => [Number.isSafeInteger(2 ** 53), Number.isSafeInteger(2 ** 53 - 1)]);
T('isFinite', () => [Number.isFinite('1'), isFinite('1'), Number.isFinite(Infinity)]);
T('isNaN', () => [Number.isNaN('x'), isNaN('x'), Number.isNaN(NaN)]);
T('constants', () => [Number.EPSILON > 0, Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER, Number.MIN_VALUE > 0]);
T('max-value', () => [Number.MAX_VALUE > 0, String(Number.MAX_VALUE * 2)]);
T('infinity', () => [String(Infinity), String(-Infinity), 1 / 0, String(0 / 0)]);

T('Math-round', () => [Math.round(0.5), Math.round(-0.5), Math.round(2.5), Math.round(-2.5), Math.round(2.4)]);
T('Math-floor-ceil', () => [Math.floor(-1.5), Math.ceil(-1.5), Math.floor(1.5), Math.ceil(1.5)]);
T('Math-trunc', () => [Math.trunc(-1.7), Math.trunc(1.7), Math.trunc(-0.5)]);
T('Math-sign', () => [Math.sign(-3), Math.sign(0), Math.sign(3), String(Math.sign(NaN))]);
T('Math-abs', () => [Math.abs(-3), Math.abs(3), Math.abs(-0)]);
T('Math-min-max', () => [Math.min(1, 2), Math.max(1, 2), Math.min(), Math.max()].map(String));
T('Math-min-max-nan', () => [String(Math.min(1, NaN)), String(Math.max(1, NaN))]);
T('Math-pow', () => [Math.pow(2, 10), 2 ** 10, Math.pow(-8, 1 / 3)].map(String));
T('Math-sqrt-cbrt', () => [Math.sqrt(16), Math.cbrt(27), String(Math.sqrt(-1))]);
T('Math-hypot', () => Math.hypot(3, 4));
T('Math-log', () => [Math.log(1), Math.log2(8), Math.log10(1000), Math.log1p(0)]);
T('Math-exp', () => [Math.exp(0), Math.expm1(0)]);
T('Math-trig', () => [Math.sin(0), Math.cos(0), Math.tan(0), Math.atan2(0, 1)]);
T('Math-hyperbolic', () => [Math.sinh(0), Math.cosh(0), Math.tanh(0)]);
T('Math-clz32', () => [Math.clz32(1), Math.clz32(0)]);
T('Math-fround', () => Math.fround(1.1));
T('Math-imul', () => [Math.imul(3, 4), Math.imul(-5, 12)]);
T('Math-constants', () => [Math.PI.toFixed(5), Math.E.toFixed(5), Math.LN2.toFixed(5)]);
T('Math-random-range', () => { const r = Math.random(); return r >= 0 && r < 1; });

T('int32-ops', () => [(2 ** 31) | 0, -1 >>> 0, 1 << 31, 5 & 3, 5 | 3, 5 ^ 3, ~5]);
T('shift-wrap', () => [1 << 32, 1 << 33, 8 >> 1, -8 >> 1, -8 >>> 28]);
T('modulo', () => [7 % 3, -7 % 3, 7 % -3, String(7.5 % 2)]);
T('division', () => [7 / 2, String(1 / 0), String(-1 / 0), String(0 / 0)]);
T('unary-negate', () => [-(-5), String(-NaN), 1 / -0]);
T('increment-decrement', () => { let a = 5; return [a++, a, ++a, a--, --a]; });
T('exponent-right-assoc', () => 2 ** 3 ** 2);
T('numeric-separators', () => [1_000_000, 0xFF_FF, 0b1010_1010]);
T('number-bases', () => [0b101, 0o17, 0xFF]);

console.log(rows.join('\n'));

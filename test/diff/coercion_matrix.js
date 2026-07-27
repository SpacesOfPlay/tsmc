// Type coercion, across the operators and conversions where the rules are
// least intuitive. Wrong answers here are silent, so the matrix is explicit.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// ToPrimitive on the + operator.
T('plus-array-object', () => [] + {});
T('plus-array-array', () => [] + []);
T('plus-object-object', () => String({} + {}));
T('plus-nested-array', () => [[1]] + [2]);
T('plus-null', () => [1 + null, 'a' + null]);
T('plus-undefined', () => [1 + undefined, 'a' + undefined]);
T('plus-bool', () => [1 + true, '1' + true]);
T('plus-date-type', () => typeof (new Date(0) + 1));

// Unary and numeric conversion.
T('unary-plus', () => [+[], +[1], +[1, 2], +{}, +'', +'  12  ', +'0x10', +'1e3']);
T('unary-plus-bool', () => [+true, +false, +null, String(+undefined)]);
T('unary-minus', () => [-'5', String(-'a')]);
T('Number-conversions', () => [Number(''), Number(' '), Number('12abc'), Number([]), Number([7])].map(String));
T('parseInt-vs-Number', () => [parseInt('12abc'), Number('12abc')].map(String));
T('parseInt-radix', () => [parseInt('0x1F'), parseInt('08'), parseInt('11', 2)]);
T('parseFloat', () => [parseFloat('3.14abc'), parseFloat('.5'), String(parseFloat('abc'))]);

// Loose equality.
T('eq-null-undefined', () => [null == undefined, null === undefined]);
T('eq-null-zero', () => [null == 0, null >= 0, null > 0]);
T('eq-nan', () => [NaN == NaN, NaN === NaN, Object.is(NaN, NaN)]);
T('eq-array-false', () => [[] == false, [0] == false, [1] == true]);
T('eq-string-number', () => ['1' == 1, '1' === 1, '' == 0]);
T('eq-object-primitive', () => [({ valueOf() { return 1; } }) == 1, ({ toString() { return '1'; } }) == 1]);
T('eq-bool-number', () => [true == 1, false == 0, true == 2]);

// Relational comparison.
T('lt-strings', () => ['a' < 'b', '10' < '9', 10 < 9]);
T('lt-mixed', () => ['10' < 9, 10 < '9']);
T('lt-nan', () => [1 < NaN, 1 > NaN, NaN <= NaN]);

// Truthiness.
T('truthy', () => [!!'', !!'0', !![], !!{}, !!0, !!-0, !!NaN, !!null, !!undefined]);

// Symbol.toPrimitive and the valueOf/toString order.
T('toPrimitive-hints', () => { const o = { [Symbol.toPrimitive](h) { return h === 'number' ? 42 : 's'; } }; return [+o, String(o), `${o}`]; });
T('valueOf-before-toString', () => { const o = { valueOf() { return 1; }, toString() { return '2'; } }; return [+o, String(o), o + ''].map(String); });
T('toString-only', () => { const o = { toString() { return '3'; } }; return [+o, o + ''].map(String); });
T('valueOf-object-falls-back', () => { const o = { valueOf() { return {}; }, toString() { return '4'; } }; return +o; });

// typeof.
T('typeof-all', () => [typeof undefined, typeof null, typeof 0, typeof 0n, typeof '', typeof true, typeof {}, typeof [], typeof (() => { }), typeof Symbol()]);
T('typeof-undeclared', () => typeof someUndeclaredName);

// String conversion of the odd values.
T('String-of', () => [String(null), String(undefined), String(NaN), String(-0), String(Infinity), String([1, [2]]), String({})]);
T('number-toString', () => [(0.1).toString(), (1e21).toString(), (1e-7).toString(), (255).toString(16)]);
T('negative-zero', () => [Object.is(-0, 0), 1 / -0, String(-0), (-0).toFixed(0)]);

// BigInt mixing.
T('bigint-compare', () => [1n < 2, 2n == 2, 2n === 2, 1n + 1n]);
T('bigint-mix-throws', () => 1n + 1);
T('bigint-to-number', () => Number(9n));

// Increment and compound assignment coercion.
T('increment-string', () => { let x = '5'; x++; return x; });
T('plus-equals-string', () => { let x = '5'; x += 1; return x; });
T('minus-equals-string', () => { let x = '5'; x -= 1; return x; });

// Bitwise operators coerce to int32.
T('bitwise-int32', () => [(2 ** 31) | 0, -1 >>> 0, 1 << 31, 5 & 3, 5 | 3, 5 ^ 3, ~5]);
T('shift-count-mod', () => [1 << 32, 1 << 33]);
T('bitwise-string', () => ['5' | 0, 'a' | 0]);

console.log(rows.join('\n'));

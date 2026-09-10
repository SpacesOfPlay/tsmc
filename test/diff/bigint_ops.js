// BigInt in the operators. The bitwise ones read a negative value as its
// infinite two's complement, the shifts floor rather than truncate, and
// mixing a BigInt with a Number is an error everywhere except comparison.
// Only the kind of a thrown error is printed.

const at = (label, f) => {
  try { console.log(label, '->', String(f())); } catch (e) { console.log(label, 'threw', e.constructor.name); }
};

// arithmetic, and what may not mix
for (const [n, f] of [
  ['1n + 2n', () => 1n + 2n],
  ['1n + 1', () => 1n + 1],
  ['1 + 1n', () => 1 + 1n],
  ['1n + "s"', () => 1n + 's'],
  ['"s" + 1n', () => 's' + 1n],
  ['+1n', () => +1n],
  ['-1n', () => -1n],
  ['7n / 2n', () => 7n / 2n],
  ['-7n / 2n', () => -7n / 2n],
  ['7n % 2n', () => 7n % 2n],
  ['-7n % 2n', () => -7n % 2n],
  ['2n ** 64n', () => 2n ** 64n],
  ['1n / 0n', () => 1n / 0n],
  ['2n ** -1n', () => 2n ** -1n],
]) at(n, f);

// bitwise, including the negative cases two's complement decides
for (const [n, f] of [
  ['3n & 5n', () => 3n & 5n],
  ['3n | 5n', () => 3n | 5n],
  ['3n ^ 5n', () => 3n ^ 5n],
  ['~0n', () => ~0n],
  ['~5n', () => ~5n],
  ['~-6n', () => ~-6n],
  ['-3n & 5n', () => -3n & 5n],
  ['-3n | 5n', () => -3n | 5n],
  ['-3n ^ 5n', () => -3n ^ 5n],
  ['-3n & -5n', () => -3n & -5n],
  ['-3n | -5n', () => -3n | -5n],
  ['-3n ^ -5n', () => -3n ^ -5n],
  ['0n & 0n', () => 0n & 0n],
  ['big & big', () => (2n ** 100n + 255n) & 0xffn],
  ['big | big', () => (2n ** 100n) | 1n],
  ['big ^ big', () => (2n ** 100n + 7n) ^ 7n],
  ['~(2n ** 100n)', () => ~(2n ** 100n)],
  ['1n & 1', () => 1n & 1],
  ['1n | 1', () => 1n | 1],
  ['1n >>> 1n', () => 1n >>> 1n],
]) at(n, f);

// shifts: left multiplies, right floors
for (const [n, f] of [
  ['1n << 0n', () => 1n << 0n],
  ['1n << 64n', () => 1n << 64n],
  ['3n << 2n', () => 3n << 2n],
  ['-3n << 2n', () => -3n << 2n],
  ['8n >> 2n', () => 8n >> 2n],
  ['-8n >> 2n', () => -8n >> 2n],
  ['-9n >> 2n', () => -9n >> 2n],
  ['-1n >> 100n', () => -1n >> 100n],
  ['1n >> 100n', () => 1n >> 100n],
  ['1n << -2n', () => 1n << -2n],
  ['8n >> -2n', () => 8n >> -2n],
  ['(2n**100n) >> 90n', () => (2n ** 100n) >> 90n],
  ['round trip', () => ((12345678901234567890n << 33n) >> 33n) === 12345678901234567890n],
]) at(n, f);

// comparison is the one place a BigInt and a Number mix
for (const [n, f] of [
  ['1n < 2', () => 1n < 2],
  ['1n == 1', () => 1n == 1],
  ['1n === 1', () => 1n === 1],
  ['1n == "1"', () => 1n == '1'],
  ['0n == false', () => 0n == false],
  ['1n < NaN', () => 1n < NaN],
  ['2n > 1.5', () => 2n > 1.5],
]) at(n, f);

// a wrapper object carries the value into all of it
for (const [n, f] of [
  ['typeof Object(1n)', () => typeof Object(1n)],
  ['Object(1n).valueOf()', () => Object(1n).valueOf()],
  ['typeof Object(1n).valueOf()', () => typeof Object(1n).valueOf()],
  ['Object(3n) & 5n', () => Object(3n) & 5n],
  ['Object(3n) + 1n', () => Object(3n) + 1n],
  ['Object(3n) == 3n', () => Object(3n) == 3n],
  ['Object(3n) < 5n', () => Object(3n) < 5n],
  ['Object(1n).toString()', () => Object(1n).toString()],
  ['Object(5) + 1', () => Object(5) + 1],
  ['Object("a") + "b"', () => Object('a') + 'b'],
  ['Object(true) + 1', () => Object(true) + 1],
]) at(n, f);

// an object with its own coercion
const toPrim = (v) => ({ [Symbol.toPrimitive]() { return v; } });
at('toPrimitive(1n) & 3n', () => toPrim(1n) & 3n);
at('toPrimitive(1n) + 1n', () => toPrim(1n) + 1n);
at('toPrimitive(1) + 1n', () => toPrim(1) + 1n);

// and the conversions
for (const [n, f] of [
  ['BigInt(1)', () => BigInt(1)],
  ['BigInt("0x10")', () => BigInt('0x10')],
  ['BigInt(1.5)', () => BigInt(1.5)],
  ['Number(1n)', () => Number(1n)],
  ['String(1n)', () => String(1n)],
  ['(255n).toString(16)', () => (255n).toString(16)],
  ['(-255n).toString(2)', () => (-255n).toString(2)],
  ['Boolean(0n)', () => Boolean(0n)],
  ['[1n, 2n].join()', () => [1n, 2n].join()],
  ['JSON.stringify(1n)', () => JSON.stringify(1n)],
]) at(n, f);

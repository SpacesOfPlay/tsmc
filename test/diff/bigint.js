// BigInt: literals, arithmetic, comparison, conversion.

console.log(typeof 1n, typeof 1, typeof BigInt(5));
console.log(10n + 20n, 100n * 100n, 2n ** 10n, 10n / 3n, 10n % 3n, -5n);
console.log(1000000000000000000000n + 1n, 5n - 8n, 7n % 3n);

// big values
console.log(2n ** 64n, 2n ** 100n);
let fact = 1n;
for (let i = 1n; i <= 25n; i++) fact *= i;
console.log(fact);

// comparison and equality
console.log(1n === 1n, 1n === 1, 1n == 1, 3n == "3", 2n > 1n, 2n > 1, 1n < 2, 5n <= 5n);
console.log(10n > 9, 10n < 9, 100n === 100n, 1n !== 2n);

// truthiness
console.log(0n ? "t" : "f", 5n ? "t" : "f", Boolean(0n), Boolean(3n), !0n, !5n);

// conversions
console.log(String(123n), `${456n}`, (255n).toString(), Number(100n));
console.log(BigInt(42), BigInt("123456789012345678901234567890"), BigInt(true), BigInt(false));
console.log(BigInt("0") === 0n, Number(2n ** 10n));

// increment / decrement / compound
let a = 5n;
a++;
console.log(a, a--, a);
let b = 100n;
b -= 30n;
b += 5n;
b *= 2n;
console.log(b);

// mixing throws TypeError; div by zero throws RangeError; bad string SyntaxError
try { 1n + 1; } catch (e) { console.log(e.constructor.name); }
try { 5n / 0n; } catch (e) { console.log(e.constructor.name); }
try { BigInt("nope"); } catch (e) { console.log(e.constructor.name); }
try { BigInt(1.5); } catch (e) { console.log(e.constructor.name); }

// in arrays / objects
console.log([1n, 2n, 3n].reduce((x, y) => x + y), [1n, 2n]);
console.log({ big: 999999999999999999999n });

// bigint fibonacci
const fib = [0n, 1n];
for (let i = 2; i < 90; i++) fib[i] = fib[i - 1] + fib[i - 2];
console.log(fib[89]);

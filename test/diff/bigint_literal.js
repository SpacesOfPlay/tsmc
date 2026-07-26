// BigInt literals in every base, with numeric separators, and the inverse
// conversion back to a string in an arbitrary radix.

const out = [];
const r = (label, v) => out.push(label + '=' + v);

// Literals by base.
r('decimal', 123n);
r('zero', 0n);
r('hex-upper', 0xFFn);
r('hex-lower', 0xffn);
r('binary', 0b1010n);
r('octal', 0o777n);

// Numeric separators are part of the literal, not of its value.
r('sep-decimal', 1_000n);
r('sep-hex', 0xFF_FFn);
r('sep-binary', 0b1010_1010n);

// Values wider than a machine word.
r('big-hex', 0xDEADBEEFn);
r('huge-hex', 0xFFFFFFFFFFFFFFFFFFFFn);
r('large-decimal', 123456789012345678901234567890n);

// They are ordinary BigInts.
r('arithmetic', 0xFFn * 0x10n + 0b1n);
r('equality', (0xFFn === 255n) + ',' + (0o10n === 8n));
r('typeof', typeof 0xFFn);
r('negate', -0xFFn);
r('mixed-base-sum', 0xFFn + 0b1n + 0o7n + 9n);

// String conversion, including a radix.
r('toString-default', (255n).toString());
r('toString-10', (255n).toString(10));
r('toString-16', (255n).toString(16));
r('toString-2', (10n).toString(2));
r('toString-8', (511n).toString(8));
r('toString-36', (35n).toString(36));
r('toString-zero', (0n).toString(16) + ',' + (0n).toString(2));
r('toString-negative', (-255n).toString(16));
r('toString-huge', (0xFFFFFFFFFFFFFFFFFFFFn).toString(16));
r('toString-huge-36', (123456789012345678901234567890n).toString(36));

// A radix outside 2..36 is a RangeError.
try { (1n).toString(1); r('radix-low', 'no-throw'); }
catch (e) { r('radix-low', e.constructor.name); }
try { (1n).toString(37); r('radix-high', 'no-throw'); }
catch (e) { r('radix-high', e.constructor.name); }

// BigInt(string) accepts the same prefixes, but not separators.
r('BigInt-hex', BigInt('0xFF'));
r('BigInt-binary', BigInt('0b101'));
r('BigInt-octal', BigInt('0o17'));
r('BigInt-decimal', BigInt('255'));
r('BigInt-negative', BigInt('-42'));
try { BigInt('1_000'); r('BigInt-separator', 'no-throw'); }
catch (e) { r('BigInt-separator', e.constructor.name); }
try { BigInt('0xZZ'); r('BigInt-invalid', 'no-throw'); }
catch (e) { r('BigInt-invalid', e.constructor.name); }

// Round trip through a hex string.
const v = 0xDEADBEEFn;
r('round-trip', BigInt('0x' + v.toString(16)) === v);

console.log(out.join('\n'));

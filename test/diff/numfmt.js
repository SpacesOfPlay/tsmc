// Number formatting: toFixed / toExponential / toPrecision / toLocaleString.

console.log((1234.5678).toFixed(2), (0).toFixed(3), (1.005).toFixed(2), (0.1 + 0.2).toFixed(2));
console.log((255).toString(16), (10).toString(2), (255).toString(8));

console.log((123456789).toExponential(2), (0.000123456).toExponential(4));
console.log((9.99).toExponential(0), (0).toExponential(3), (255).toExponential());
console.log((1.5).toExponential(), (12345.678).toExponential(3));

console.log((12345.678).toPrecision(4), (0.00001234).toPrecision(3));
console.log((123).toPrecision(6), (0).toPrecision(3), (12345).toPrecision());
console.log((0.5).toPrecision(1), (999.9).toPrecision(2));

console.log((1000000).toLocaleString(), (1234.5678).toLocaleString());
console.log((1.5).toLocaleString(), (-9876543.21).toLocaleString(), (0).toLocaleString());

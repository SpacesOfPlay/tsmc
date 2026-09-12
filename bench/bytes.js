// Typed-array element loops: reads and writes go through the view rather than
// the property table, and the values stay unboxed integers.
const n = 40000;
const u8 = new Uint8Array(n);
const i32 = new Int32Array(n >> 2);
const f64 = new Float64Array(n >> 3);
let acc = 0;
for (let iter = 0; iter < 44; iter++) {
  for (let i = 0; i < n; i++) u8[i] = (i * 7) & 255;
  for (let i = 0; i < i32.length; i++) i32[i] = i - 1000;
  for (let i = 0; i < f64.length; i++) f64[i] = i / 3;
  for (let i = 0; i < n; i++) acc = (acc + u8[i]) | 0;
  for (let i = 0; i < i32.length; i++) acc = (acc + i32[i]) | 0;
  for (let i = 0; i < f64.length; i++) acc = (acc + (f64[i] | 0)) | 0;
  acc = (acc + u8.subarray(0, 100).length) | 0;
}
console.log(acc);

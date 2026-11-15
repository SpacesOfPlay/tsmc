// Parenthesized assignments nested sixty deep, as a minifier writes a
// chain of iterator reads (reCAPTCHA's bundle): every '(' looks like an
// arrow's parameter list until its ')' is not followed by '=>'. Each is
// tried as an arrow head once; tried again at every level, this never
// finished.
let a0, a1, a2, a3, a4, a5, a6, a7, a8, a9;
let n = 0;
const it = { next() { n++; return { value: n }; } };
const r = (a0=(a1=(a2=(a3=(a4=(a5=(a6=(a7=(a8=(a9=(a0=(a1=(a2=(a3=(a4=(a5=(a6=(a7=(a8=(a9=(a0=(a1=(a2=(a3=(a4=(a5=(a6=(a7=(a8=(a9=(a0=(a1=(a2=(a3=(a4=(a5=(a6=(a7=(a8=(a9=(a0=(a1=(a2=(a3=(a4=(a5=(a6=(a7=(a8=(a9=(a0=(a1=(a2=(a3=(a4=(a5=(a6=(a7=(a8=(a9=
  it.next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value,it).next().value);
console.log(r, n, a0, a9);

// an arrow inside the chain is still an arrow
const f = (x = (y = (z = 1))) => x + y + z;
console.log(f());

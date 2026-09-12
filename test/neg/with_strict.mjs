// expect: Strict mode code may not include a with statement
// module code is strict, with no directive to say so
const o = { a: 1 };
with (o) { a; }

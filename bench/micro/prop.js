function P(i) { this.a = i; this.b = 2; this.c = 3; this.d = 4; this.e = 5; this.f = 6; this.g = 7; this.h = 8; this.k = 9; this.m = 10; }
const os = []; for (let i = 0; i < 64; i++) os.push(new P(i));
let s = 0; for (let i = 0; i < 20000000; i++) { s += os[i & 63].m; } console.log(s);

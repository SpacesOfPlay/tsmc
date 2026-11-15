class C { constructor() { this.v = 1; } get() { return this.v; } } const c = new C(); let s = 0; for (let i = 0; i < 20000000; i++) { s += c.get(); } console.log(s);

// test_modern.mc — M7 syntax: classes, destructuring, spread, optional
// chaining, accessors, for-of/for-in, labels.

import str;
import "../helpers/check.mc";
import "../../src/value.mc";
import "../../src/object.mc";
import "../../src/vm.mc";
import "../../src/builtins.mc";

Value[48] g_probes;
i32 g_probe_n = 0;

Value probe_native(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    if argc > 0 && g_probe_n < 48 {
        g_probes[g_probe_n] = *(args);
        g_probe_n++;
    }
    return value_undefined();
}

i32 run_snippet(str src, bool stress) {
    g_probe_n = 0;
    VM m;
    vm_init(&m);
    builtins_install(&m);
    m.heap.stress = stress;
    vm_set_global(&m, "probe", vm_make_native(&m, &probe_native, "probe"));
    i32 st = vm_run_source(&m, src, "snippet");
    vm_destroy(&m);
    return st;
}

void check_probes(str src, f64* want, i32 n, str what) {
    i32 st = run_snippet(src, false);
    check_eq(st, 0, what);
    check_eq(g_probe_n, n, what);
    if g_probe_n != n { return; }
    for i32 i = 0; i < n; i++ {
        f64 got = js_to_number(g_probes[i]);
        if got != *(want + i) {
            eprint("  FAIL: {} probe {} (got {}, want {})\n", what, i, got, *(want + i));
            g_checks_failed++;
        }
        g_checks_run++;
    }
}

i32 main() {
    // classes: fields, methods, statics, this
    f64[5] w1 = { 3.0, 12.0, 7.0, 1.0, 99.0 };
    check_probes("class P { x = 1; constructor(y) { this.y = y; } sum() { return this.x + this.y; } scaled(k) { return this.sum() * k; } static make(y) { return new P(y); } static tag = 99; } const p = new P(2); probe(p.sum()); probe(p.scaled(4)); probe(P.make(6).sum()); probe(p instanceof P ? 1 : 0); probe(P.tag);",
        &w1[0], 5, "class basics");

    // inheritance: super ctor, super methods, instanceof chain
    f64[6] w2 = { 30.0, 33.0, 1.0, 1.0, 8.0, 5.0 };
    check_probes("class A { constructor(v) { this.v = v; } get10() { return this.v * 10; } } class B extends A { constructor(v) { super(v); this.w = 3; } get10() { return super.get10() + this.w; } } const b = new B(3); probe(new A(3).get10()); probe(b.get10()); probe(b instanceof A ? 1 : 0); probe(b instanceof B ? 1 : 0); class C extends A {} probe(new C(8).v); probe(new C(5).get10() / 10);",
        &w2[0], 6, "inheritance");

    // accessors in classes and object literals
    f64[4] w3 = { 10.0, 6.0, 25.0, 42.0 };
    check_probes("class T { constructor() { this.n = 5; } get double() { return this.n * 2; } set double(v) { this.n = v / 2; } } const t = new T(); probe(t.double); t.double = 12; probe(t.n); const o = { base: 5, get sq() { return this.base * this.base; }, set sq(v) { this.base = v; } }; probe(o.sq); o.sq = 42; probe(o.base);",
        &w3[0], 4, "accessors");

    // destructuring declarations
    f64[7] w4 = { 1.0, 2.0, 3.0, 9.0, 4.0, 5.0, 2.0 };
    check_probes("const [a, b = 2, , ...rest] = [1, undefined, 8, 4, 5]; probe(a); probe(b); const { x, y: z = 9, ...others } = { x: 3, k: 1, m: 2 }; probe(x); probe(z); probe(rest[0]); probe(rest[1]); probe(Object.keys(others).length);",
        &w4[0], 7, "destructuring decls");

    // destructuring params, nested, assignment form
    f64[6] w5 = { 3.0, 7.0, 30.0, 8.0, 9.0, 4.0 };
    check_probes("function f({ a, b: { c } }, [d]) { return a + c + d; } probe(f({ a: 1, b: { c: 2 } }, [0])); function g({ v = 7 } = {}) { return v; } probe(g()); probe(g({ v: 30 })); let m = 0; let n = 0; [m, n] = [8, 9]; probe(m); probe(n); const obj = { q: 0 }; ({ q: obj.q } = { q: 4 }); probe(obj.q);",
        &w5[0], 6, "destructuring params and assigns");

    // spread and rest
    f64[7] w6 = { 6.0, 5.0, 1.0, 2.0, 10.0, 3.0, 7.0 };
    check_probes("function sum(...xs) { return xs.reduce((a, x) => a + x, 0); } probe(sum(1, 2, 3)); const parts = [2, 3]; const all = [1, ...parts, 4]; probe(sum(...parts)); probe(all[0]); probe(all[1]); probe(sum(...all)); const merged = { a: 1, ...{ b: 2, c: 4 } }; probe(Object.keys(merged).length); probe(merged.a + merged.b + merged.c);",
        &w6[0], 7, "spread and rest");

    // optional chaining
    f64[6] w7 = { 5.0, 1.0, 1.0, 1.0, 3.0, 1.0 };
    check_probes("const o = { a: { b: 5 }, f() { return 3; } }; probe(o.a?.b); probe(o.x?.y === undefined ? 1 : 0); probe(o.x?.y?.z === undefined ? 1 : 0); const nul = null; probe(nul?.anything === undefined ? 1 : 0); probe(o.f?.()); probe(o.missing?.() === undefined ? 1 : 0);",
        &w7[0], 6, "optional chaining");

    // for-of and for-in
    f64[5] w8 = { 10.0, 6.0, 3.0, 60.0, 3.0 };
    check_probes("let s = 0; for (const v of [1, 2, 3, 4]) { s += v; } probe(s); let t = 0; for (const [i, v] of [[1, 2], [3, 0]]) { t += i + v; } probe(t); let cs = 0; for (const ch of 'abc') { cs += 1; } probe(cs); let ks = ''; let vs = 0; const obj = { p: 10, q: 20, r: 30 }; for (const k in obj) { ks += k; vs += obj[k]; } probe(vs); probe(ks.length);",
        &w8[0], 5, "for-of and for-in");

    // labels
    f64[2] w9 = { 30.0, 12.0 };
    check_probes("let s = 0; outer: for (let i = 0; i < 5; i++) { for (let j = 0; j < 5; j++) { if (j > i) { continue outer; } if (i === 4) { break outer; } s += 1 + i; } } probe(s); let t = 0; blk: { t = 12; if (t > 0) { break blk; } t = 99; } probe(t);",
        &w9[0], 2, "labels");

    // loop closures capture per-iteration values
    f64[3] w10 = { 0.0, 1.0, 2.0 };
    check_probes("const fns = []; for (let i = 0; i < 3; i++) { fns.push(() => i); } probe(fns[0]()); probe(fns[1]()); probe(fns[2]());",
        &w10[0], 3, "loop closure capture");

    f64[3] w11 = { 1.0, 2.0, 3.0 };
    check_probes("const fns = []; for (const v of [1, 2, 3]) { fns.push(() => v); } probe(fns[0]()); probe(fns[1]()); probe(fns[2]());",
        &w11[0], 3, "for-of closure capture");

    // getter/setter through the prototype chain + Object.keys on accessors
    f64[3] w12 = { 21.0, 11.0, 1.0 };
    check_probes("class Base { get val() { return 21; } } class Kid extends Base {} probe(new Kid().val); const src = { get g() { return 11; } }; const copy = Object.assign({}, src); probe(copy.g); probe(JSON.stringify(src) === '{\"g\":11}' ? 1 : 0);",
        &w12[0], 3, "accessors via chain and reflection");

    // spread in new, method chains on class instances
    f64[2] w13 = { 12.0, 30.0 };
    check_probes("class V { constructor(x, y) { this.x = x; this.y = y; } mul() { return this.x * this.y; } } const args = [3, 4]; probe(new V(...args).mul()); class W extends V { constructor(...a) { super(...a); } } probe(new W(5, 6).mul());",
        &w13[0], 2, "spread constructors");

    // GC stress across the new paths
    {
        g_probe_n = 0;
        VM m;
        vm_init(&m);
        builtins_install(&m);
        m.heap.stress = true;
        vm_set_global(&m, "probe", vm_make_native(&m, &probe_native, "probe"));
        i32 st = vm_run_source(&m,
            "class Pt { constructor(x) { this.x = x; } get dbl() { return this.x * 2; } } const ps = [1, 2, 3].map(x => new Pt(x)); const [first, ...more] = ps; probe(first.dbl + more.length + [...'ab'].length);",
            "stress");
        vm_destroy(&m);
        check_eq(st, 0, "m7 gc stress");
        check_eq(g_probe_n, 1, "m7 gc stress probes");
        check(js_to_number(g_probes[0]) == 6.0, "m7 gc stress value");
    }

    return check_done("test_modern");
}

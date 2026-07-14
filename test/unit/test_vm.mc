// test_vm.mc — end-to-end snippets through parse → lower → compile → run.
//
// Scripts call probe(v); probed numbers land in g_probes for checks.
// Only immediate values (numbers, bools) are probed — they survive GC.

import str;
import "../helpers/check.mc";
import "../../src/value.mc";
import "../../src/object.mc";
import "../../src/vm.mc";

Value[32] g_probes;
i32 g_probe_n = 0;

Value probe_native(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    if argc > 0 && g_probe_n < 32 {
        g_probes[g_probe_n] = *(args);
        g_probe_n++;
    }
    return value_undefined();
}

i32 run_snippet(str src, bool stress) {
    g_probe_n = 0;
    VM m;
    vm_init(&m);
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

void check_status(str src, i32 want, str what) {
    check_eq(run_snippet(src, false), want, what);
}

i32 main() {
    f64[6] w1 = { 7.0, 9.0, 2.5, 1024.0, 1.0, -1.0 };
    check_probes("probe(1 + 2 * 3); probe((1 + 2) * 3); probe(10 / 4); probe(2 ** 10); probe(7 % 3); probe(-7 % 3);",
        &w1[0], 6, "arithmetic");

    f64[3] w2 = { 1.0, 2.0, 1.0 };
    check_probes("function counter() { let n = 0; return function() { n = n + 1; return n; }; } const c = counter(); probe(c()); probe(c()); const d = counter(); probe(d());",
        &w2[0], 3, "closures");

    f64[1] w3 = { 2.0 };
    check_probes("function mk() { let x = 0; return [function() { x = x + 1; }, function() { return x; }]; } const fns = mk(); fns[0](); fns[0](); probe(fns[1]());",
        &w3[0], 1, "shared capture");

    f64[2] w4 = { 42.0, 1.0 };
    check_probes("probe(f()); function f() { return 42; } var v = 1; probe(g()); function g() { return v; }",
        &w4[0], 2, "hoisting");

    f64[2] w5 = { 1.0, 5.0 };
    check_probes("try { x; } catch (e) { probe(1); } let x = 5; probe(x);",
        &w5[0], 2, "tdz");

    f64[3] w6 = { 4.0, 3.0, 5.0 };
    check_probes("let s = 0; for (let i = 0; i < 5; i = i + 1) { if (i % 2 === 0) { continue; } s = s + i; } probe(s); let i = 0; while (i < 3) { i++; } probe(i); do { i++; } while (i < 5); probe(i);",
        &w6[0], 3, "loops");

    f64[3] w7 = { 10.0, 23.0, 99.0 };
    check_probes("function sw(x) { switch (x) { case 1: return 10; case 2: case 3: return 23; default: return 99; } } probe(sw(1)); probe(sw(3)); probe(sw(7));",
        &w7[0], 3, "switch");

    f64[4] w8 = { 7.0, 1.0, 1.0, 0.0 };
    check_probes("function P(x, y) { this.x = x; this.y = y; } P.prototype.sum = function() { return this.x + this.y; }; const p = new P(3, 4); probe(p.sum()); probe(p instanceof P ? 1 : 0); probe('x' in p ? 1 : 0); delete p.x; probe('x' in p ? 1 : 0);",
        &w8[0], 4, "prototypes");

    f64[4] w9 = { 6.0, 2.0, 1.0, 12.0 };
    check_probes("const a = [1, 2, 3]; a[5] = 9; probe(a.length); probe(a[1]); probe(a[4] === undefined ? 1 : 0); a[1] += 10; probe(a[1]);",
        &w9[0], 4, "arrays");

    f64[6] w10 = { 1.0, 1.0, 1.0, 0.0, 0.0, 1.0 };
    check_probes("probe(1 == '1' ? 1 : 0); probe(1 === 1 ? 1 : 0); probe(null == undefined ? 1 : 0); probe(null === undefined ? 1 : 0); probe(NaN === NaN ? 1 : 0); probe('' == 0 ? 1 : 0);",
        &w10[0], 6, "equality");

    f64[5] w11 = { 4.0, 1.0, 1.0, 42.0, 0.0 };
    check_probes("const s = 'abc' + 1; probe(s.length); probe(s === 'abc1' ? 1 : 0); probe('b' < 'c' ? 1 : 0); probe(+'42'); probe(+'4x' === +'4x' ? 1 : 0);",
        &w11[0], 5, "strings");

    f64[7] w12 = { 1.0, 7.0, 6.0, -6.0, 1024.0, -4.0, 15.0 };
    check_probes("probe(5 & 3); probe(5 | 3); probe(5 ^ 3); probe(~5); probe(1 << 10); probe(-8 >> 1); probe(-8 >>> 28);",
        &w12[0], 7, "bit ops");

    f64[4] w13 = { 10.0, 1.0, 20.0, 2.0 };
    check_probes("function f() { try { return 1; } finally { probe(10); } } probe(f()); function g() { try { throw { name: 'E', message: 'm' }; } catch (e) { return 2; } finally { probe(20); } } probe(g());",
        &w13[0], 4, "finally");

    f64[6] w14 = { 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 };
    check_probes("probe(typeof 1 === 'number' ? 1 : 0); probe(typeof 'a' === 'string' ? 1 : 0); probe(typeof undefined === 'undefined' ? 1 : 0); probe(typeof null === 'object' ? 1 : 0); probe(typeof probe === 'function' ? 1 : 0); probe(typeof zzz === 'undefined' ? 1 : 0);",
        &w14[0], 6, "typeof");

    f64[5] w15 = { 7.0, 2.0, 5.0, 0.0, 3.0 };
    check_probes("probe(0 || 7); probe(1 && 2); probe(null ?? 5); probe(0 ?? 9); let u; u ??= 3; probe(u);",
        &w15[0], 5, "logical");

    f64[2] w16 = { 3.0, 1.0 };
    check_probes("const n = 3; probe(`a${n}b`.length); probe(`${1 + 1}` === '2' ? 1 : 0);",
        &w16[0], 2, "templates");

    f64[4] w17 = { 5.0, 6.0, 7.0, 2.0 };
    check_probes("let x = 5; probe(x++); probe(x); probe(++x); const o = { n: 1 }; o.n++; probe(o.n);",
        &w17[0], 4, "updates");

    f64[3] w18 = { 11.0, 3.0, 5.0 };
    check_probes("const add = (a, b = 10) => a + b; probe(add(1)); probe(add(1, 2)); function T() { this.v = 5; this.get = () => this.v; } const t = new T(); probe(t.get());",
        &w18[0], 3, "defaults and arrow this");

    f64[1] w19 = { 610.0 };
    check_probes("function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); } probe(fib(15));",
        &w19[0], 1, "recursion");

    // status codes
    check_status("throw { name: 'X', message: 'y' };", 1, "uncaught exit 1");
    check_status("async function f() {}", 2, "unsupported exit 2");
    check_status("syntax error here(", 2, "parse error exit 2");

    // GC stress: collect on every allocation through the full pipeline
    {
        i32 st = run_snippet("let s = ''; for (let i = 0; i < 200; i++) { s = s + 'x'; } probe(s.length); const arr = []; for (let i = 0; i < 100; i++) { arr[i] = { v: i }; } let tot = 0; for (let i = 0; i < 100; i++) { tot += arr[i].v; } probe(tot);", false);
        check_eq(st, 0, "alloc churn");
        check_eq(g_probe_n, 2, "alloc churn probes");
        check(js_to_number(g_probes[0]) == 200.0, "string growth");
        check(js_to_number(g_probes[1]) == 4950.0, "object sum");
    }
    {
        g_probe_n = 0;
        VM m;
        vm_init(&m);
        m.heap.stress = true;
        vm_set_global(&m, "probe", vm_make_native(&m, &probe_native, "probe"));
        i32 st = vm_run_source(&m, "function counter() { let n = 0; return function() { n = n + 1; return n; }; } const c = counter(); c(); c(); const o = { a: [1, 2, 3] }; probe(c() + o.a.length + ('xy' + 'z').length);", "stress");
        vm_destroy(&m);
        check_eq(st, 0, "gc stress run");
        check_eq(g_probe_n, 1, "gc stress probes");
        check(js_to_number(g_probes[0]) == 9.0, "gc stress value");
    }

    return check_done("test_vm");
}

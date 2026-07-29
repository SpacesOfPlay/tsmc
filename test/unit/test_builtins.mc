// test_builtins.mc — the standard library surface through the pipeline.

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

i32 run_snippet(str src) {
    g_probe_n = 0;
    VM m;
    vm_init(&m);
    builtins_install(&m);
    m.quiet_errors = true;
    vm_set_global(&m, "probe", vm_make_native(&m, &probe_native, "probe"));
    i32 st = vm_run_source(&m, src, "snippet");
    vm_destroy(&m);
    return st;
}

void check_probes(str src, f64* want, i32 n, str what) {
    i32 st = run_snippet(src);
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
    check_eq(run_snippet(src), want, what);
}

i32 main() {
    f64[8] w1 = { 2.0, 5.0, 6.0, 1.0, 6.0, 3.0, 3.0, 9.0 };
    check_probes("const a = [3, 1, 2]; probe(a.indexOf(2)); a.push(5, 6); probe(a.length); probe(a.pop()); probe(a.includes(3) ? 1 : 0); const b = a.concat([7, 8]); probe(b.length); probe(a.slice(1).length); probe(a.shift()); a.unshift(9); probe(a[0]);",
        &w1[0], 8, "array basics");

    f64[8] w2 = { 8.0, 2.0, 10.0, 110.0, 1.0, 1.0, 3.0, 2.0 };
    check_probes("const xs = [1, 2, 3, 4]; probe(xs.map(x => x * 2)[3]); probe(xs.filter(x => x % 2 === 0).length); let s = 0; xs.forEach(x => { s += x; }); probe(s); probe(xs.reduce((a, x) => a + x, 100)); probe(xs.some(x => x > 3) ? 1 : 0); probe(xs.every(x => x > 0) ? 1 : 0); probe(xs.find(x => x > 2)); probe(xs.findIndex(x => x > 2));",
        &w2[0], 8, "array callbacks");

    f64[4] w3 = { 1.0, 10.0, 10.0, 1.0 };
    check_probes("const ys = [3, 1, 10, 2]; ys.sort((a, b) => a - b); probe(ys[0]); probe(ys[3]); ys.reverse(); probe(ys[0]); probe([2, 10, 1].sort().join('-') === '1-10-2' ? 1 : 0);",
        &w3[0], 4, "sort reverse join");

    f64[5] w4 = { 2.0, 2.0, 4.0, 9.0, 4.0 };
    check_probes("const zs = [1, 2, 3, 4, 5]; const rem = zs.splice(1, 2, 9); probe(rem.length); probe(rem[0]); probe(zs.length); probe(zs[1]); probe(zs[2]);",
        &w4[0], 5, "splice");

    f64[13] w5 = { 6.0, 1.0, 1.0, 2.0, 1.0, 1.0, 1.0, 1.0, 72.0, 1.0, 1.0, 1.0, 1.0 };
    check_probes("const s = 'Hello World'; probe(s.indexOf('World')); probe(s.slice(0, 5) === 'Hello' ? 1 : 0); probe(s.toUpperCase() === 'HELLO WORLD' ? 1 : 0); probe(s.split(' ').length); probe('  x '.trim().length); probe('ab'.repeat(3) === 'ababab' ? 1 : 0); probe('5'.padStart(3, '0') === '005' ? 1 : 0); probe('a-b-c'.replaceAll('-', '+') === 'a+b+c' ? 1 : 0); probe(s.charCodeAt(0)); probe(String.fromCharCode(72, 105) === 'Hi' ? 1 : 0); probe(s.startsWith('Hell') ? 1 : 0); probe(s.endsWith('rld') ? 1 : 0); probe(s.substring(6, 4) === 'o ' ? 1 : 0);",
        &w5[0], 13, "strings");

    f64[7] w6 = { 2.0, 1.0, 2.0, 3.0, 1.0, 0.0, 2.0 };
    check_probes("const o = { b: 1, a: 2 }; const ks = Object.keys(o); probe(ks.length); probe(ks[0] === 'b' ? 1 : 0); probe(Object.values(o)[1]); const t = Object.assign({}, o, { c: 3 }); probe(Object.keys(t).length); probe(o.hasOwnProperty('a') ? 1 : 0); probe(o.hasOwnProperty('z') ? 1 : 0); const e = Object.entries(o); probe(e[1][1]);",
        &w6[0], 7, "object statics");

    f64[17] w7 = { 9.0, 2.0, 3.0, 3.0, 8.0, -2.0, 9.0, 256.0, 42.0, 1.0, 0.0, 123.0, 255.0, 3.5, 1.0, 1.0, 1.0 };
    check_probes("probe(Math.max(1, 9, 3)); probe(Math.min(4, 2)); probe(Math.floor(3.7)); probe(Math.round(2.5)); probe(Math.abs(-8)); probe(Math.trunc(-2.7)); probe(Math.sqrt(81)); probe(Math.pow(2, 8)); probe(Number('42')); probe(Number.isInteger(5) ? 1 : 0); probe(Number.isInteger(5.5) ? 1 : 0); probe(parseInt('123abc')); probe(parseInt('ff', 16)); probe(parseFloat('3.5rest')); probe(isNaN('x') ? 1 : 0); probe((3.14159).toFixed(2) === '3.14' ? 1 : 0); probe((255).toString(16) === 'ff' ? 1 : 0);",
        &w7[0], 17, "number and math");

    f64[6] w8 = { 1.0, 1.0, 2.0, 1.0, 1.0, 2.5 };
    check_probes("const j = JSON.stringify({ a: 1, b: [true, null], c: 'x' }); probe(j === '{\"a\":1,\"b\":[true,null],\"c\":\"x\"}' ? 1 : 0); const p = JSON.parse(j); probe(p.a); probe(p.b.length); probe(p.b[0] ? 1 : 0); probe(p.c === 'x' ? 1 : 0); probe(JSON.parse('[1, 2.5, \"s\"]')[1]);",
        &w8[0], 6, "json round trip");

    f64[6] w9 = { 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 };
    check_probes("try { null.x; } catch (e) { probe(e instanceof TypeError ? 1 : 0); probe(e instanceof Error ? 1 : 0); probe(e.name === 'TypeError' ? 1 : 0); } try { throw new Error('boom'); } catch (e) { probe(e.message === 'boom' ? 1 : 0); probe(e.toString() === 'Error: boom' ? 1 : 0); } try { undef_var; } catch (e) { probe(e instanceof ReferenceError ? 1 : 0); }",
        &w9[0], 6, "errors");

    f64[4] w10 = { 13.0, 17.0, 21.0, 102.0 };
    check_probes("function f(a, b) { return this.k + a + b; } const o2 = { k: 10 }; probe(f.call(o2, 1, 2)); probe(f.apply(o2, [3, 4])); const g2 = f.bind(o2, 5); probe(g2(6)); const h2 = f.bind({ k: 100 }); probe(h2(1, 1));",
        &w10[0], 4, "call apply bind");

    f64[3] w11 = { 2.0, 1.0, 4.0 };
    check_probes("const la = [1, 2, 3, 4]; la.length = 2; probe(la.length); probe(la[2] === undefined ? 1 : 0); la.length = 4; probe(la.length);",
        &w11[0], 3, "length assignment");

    f64[6] w12 = { 1.0, 0.0, 3.0, 20.0, 3.0, 5.0 };
    check_probes("probe(Array.isArray([]) ? 1 : 0); probe(Array.isArray('no') ? 1 : 0); probe(Array.of(1, 2, 3).length); probe(Array.from([1, 2], x => x * 10)[1]); probe(Array.from('abc').length); probe(new Array(5).length);",
        &w12[0], 6, "array statics");

    f64[2] w13 = { 1.0, 1.0 };
    check_probes("probe(JSON.stringify(undefined) === undefined ? 1 : 0); probe(JSON.stringify({ a: undefined, b: 1 }) === '{\"b\":1}' ? 1 : 0);",
        &w13[0], 2, "json omissions");

    check_status("const c = { a: 1 }; c.self = c; JSON.stringify(c);", 1, "json cycle throws");
    check_status("JSON.parse('{bad');", 1, "json parse error throws");

    // GC stress through reentrant natives: callbacks, sort, JSON
    {
        g_probe_n = 0;
        VM m;
        vm_init(&m);
        builtins_install(&m);
        m.quiet_errors = true;
        m.heap.stress = true;
        vm_set_global(&m, "probe", vm_make_native(&m, &probe_native, "probe"));
        i32 st = vm_run_source(&m,
            "const xs = [4, 1, 3, 2].sort((a, b) => a - b).map(x => x * 10); const j = JSON.parse(JSON.stringify({ v: xs })); probe(j.v.join('') === '10203040' ? 1 : 0); probe('a b c'.split(' ').map(s => s.toUpperCase()).join('-') === 'A-B-C' ? 1 : 0);",
            "stress");
        vm_destroy(&m);
        check_eq(st, 0, "builtins gc stress");
        check_eq(g_probe_n, 2, "builtins gc stress probes");
        check(js_to_number(g_probes[0]) == 1.0, "stress sort map json");
        check(js_to_number(g_probes[1]) == 1.0, "stress split map join");
    }

    return check_done("test_builtins");
}

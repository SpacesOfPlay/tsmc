// test_collections.mc — Map, Set, Date, and regex through the pipeline.

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
    m.quiet_errors = true;
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
    // Map basics
    f64[7] w1 = { 3.0, 10.0, 1.0, 0.0, 2.0, 30.0, 1.0 };
    check_probes("const m = new Map(); m.set('a', 10).set('b', 20).set('c', 30); probe(m.size); probe(m.get('a')); probe(m.has('b') ? 1 : 0); probe(m.has('z') ? 1 : 0); m.delete('a'); probe(m.size); probe(m.get('c')); m.set('b', 99); probe(m.size === 2 ? 1 : 0);",
        &w1[0], 7, "map basics");

    // Map key types and iteration order
    f64[4] w2 = { 3.0, 100.0, 200.0, 6.0 };
    check_probes("const m = new Map([[1, 100], ['x', 200], [true, 300]]); probe(m.size); probe(m.get(1)); probe(m.get('x')); let s = 0; for (const [k, v] of m) { s += 1; } probe(s * 2);",
        &w2[0], 4, "map key types");

    // Map forEach, keys, values, entries
    f64[3] w3 = { 60.0, 6.0, 60.0 };
    check_probes("const m = new Map([['a', 10], ['b', 20], ['c', 30]]); let vs = 0; m.forEach((v, k) => { vs += v; }); probe(vs); let ks = 0; for (const k of m.keys()) { ks += k.length; } probe(ks + 3); probe([...m.values()].reduce((a, b) => a + b, 0));",
        &w3[0], 3, "map iteration");

    // Set basics: {1,2,3} - {1} = {2,3}, sum 5
    f64[6] w4 = { 3.0, 1.0, 0.0, 2.0, 5.0, 4.0 };
    check_probes("const s = new Set(); s.add(1).add(2).add(2).add(3); probe(s.size); probe(s.has(2) ? 1 : 0); probe(s.has(9) ? 1 : 0); s.delete(1); probe(s.size); probe([...s].reduce((a, b) => a + b, 0)); const s2 = new Set([1, 1, 2, 2, 3, 3, 4]); probe(s2.size);",
        &w4[0], 6, "set basics");

    // SameValueZero: NaN keys, +0/-0
    f64[3] w5 = { 1.0, 1.0, 1.0 };
    check_probes("const m = new Map(); m.set(NaN, 'a'); probe(m.get(NaN) === 'a' ? 1 : 0); const s = new Set([NaN, NaN]); probe(s.size); m.set(0, 'z'); probe(m.get(-0) === 'z' ? 1 : 0);",
        &w5[0], 3, "samevaluezero");

    // regex test/exec: '12-345' matches at index 0
    f64[6] w6 = { 1.0, 0.0, 0.0, 12.0, 345.0, 1.0 };
    check_probes("probe(/\\d+/.test('abc123') ? 1 : 0); probe(/^\\d+$/.test('12a') ? 1 : 0); const m = /(\\d+)-(\\d+)/.exec('12-345'); probe(m.index); probe(Number(m[1])); probe(Number(m[2])); probe(m[0] === '12-345' ? 1 : 0);",
        &w6[0], 6, "regex exec");

    // String regex methods: 'a,b,,c'.split(/,/) = ['a','b','','c'] len 4
    f64[6] w7 = { 42.0, 1.0, 4.0, 1.0, 4.0, 1.0 };
    check_probes("probe(Number('foo42bar'.match(/\\d+/)[0])); probe('a1b2c3'.match(/\\d/g).length === 3 ? 1 : 0); probe('one two three four'.split(/\\s+/).length); probe('Hello World'.replace(/o/g, '0') === 'Hell0 W0rld' ? 1 : 0); probe('a,b,,c'.split(/,/).length); probe('abc'.search(/b/) === 1 ? 1 : 0);",
        &w7[0], 6, "string regex");

    // replace with capture substitution and function
    f64[3] w8 = { 1.0, 1.0, 1.0 };
    check_probes("probe('2024-01-15'.replace(/(\\d+)-(\\d+)-(\\d+)/, '$3/$2/$1') === '15/01/2024' ? 1 : 0); probe('hello'.replace(/l/g, (m) => m.toUpperCase()) === 'heLLo' ? 1 : 0); probe('a1b2'.replace(/\\d/g, (d) => String(Number(d) * 2)) === 'a2b4' ? 1 : 0);",
        &w8[0], 3, "replace substitution");

    // regex flags
    f64[3] w9 = { 1.0, 1.0, 1.0 };
    check_probes("probe(/abc/i.test('XABCY') ? 1 : 0); probe('line1\\nline2'.match(/^line\\d/gm).length === 2 ? 1 : 0); probe(/a.b/s.test('a\\nb') ? 1 : 0);",
        &w9[0], 3, "regex flags");

    // Date decomposition (fixed timestamp: 2024-01-15T10:30:45.123Z)
    f64[7] w10 = { 2024.0, 0.0, 15.0, 10.0, 30.0, 45.0, 123.0 };
    check_probes("const d = new Date(1705314645123); probe(d.getFullYear()); probe(d.getMonth()); probe(d.getDate()); probe(d.getHours()); probe(d.getMinutes()); probe(d.getSeconds()); probe(d.getMilliseconds());",
        &w10[0], 7, "date decompose");

    // Date compose + ISO round trip
    f64[3] w11 = { 1.0, 1.0, 0.0 };
    check_probes("const d = new Date(2000, 0, 1, 0, 0, 0, 0); probe(d.getTime() === 946684800000 ? 1 : 0); probe(new Date(1705314645123).toISOString() === '2024-01-15T10:30:45.123Z' ? 1 : 0); probe(new Date(0).getFullYear() - 1970);",
        &w11[0], 3, "date compose");

    // Map/Set as JSON and typical usage
    f64[2] w12 = { 3.0, 1.0 };
    check_probes("function countWords(text) { const counts = new Map(); for (const w of text.split(' ')) { counts.set(w, (counts.get(w) || 0) + 1); } return counts; } const c = countWords('a b a c a'); probe(c.get('a')); probe(c.size === 3 ? 1 : 0);",
        &w12[0], 2, "map word count");

    // error cases
    check_eq(run_snippet("new RegExp('(unclosed');", false), 1, "bad regex throws");

    // GC stress across Map/Set/regex
    {
        g_probe_n = 0;
        VM m;
        vm_init(&m);
        builtins_install(&m);
        m.quiet_errors = true;
        m.heap.stress = true;
        vm_set_global(&m, "probe", vm_make_native(&m, &probe_native, "probe"));
        i32 st = vm_run_source(&m,
            "const m = new Map(); for (let i = 0; i < 50; i++) { m.set('k' + i, i * i); } let s = 0; for (const v of m.values()) { s += v; } probe(s); const matches = 'a1b22c333d4444'.match(/\\d+/g); probe(matches.reduce((a, x) => a + x.length, 0));",
            "stress");
        vm_destroy(&m);
        check_eq(st, 0, "collections gc stress");
        check_eq(g_probe_n, 2, "collections gc stress probes");
        check(js_to_number(g_probes[0]) == 40425.0, "map sum of squares");
        check(js_to_number(g_probes[1]) == 10.0, "regex match lengths");
    }

    return check_done("test_collections");
}

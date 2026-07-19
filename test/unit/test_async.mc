// test_async.mc — generators, symbols, iterators, promises, async/await,
// timers, and the event loop.

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
    // generators: state machine, args, for-of, spread
    f64[6] w1 = { 1.0, 2.0, 3.0, 1.0, 6.0, 3.0 };
    check_probes("function* g() { yield 1; yield 2; yield 3; } const it = g(); probe(it.next().value); probe(it.next().value); probe(it.next().value); probe(it.next().done ? 1 : 0); let s = 0; for (const v of g()) { s += v; } probe(s); probe([...g()].length);",
        &w1[0], 6, "generator basics");

    // generator receiving values via next(), and return value
    f64[3] w2 = { 10.0, 25.0, 100.0 };
    check_probes("function* adder() { let total = 0; while (true) { const x = yield total; if (x === undefined) break; total += x; } return 100; } const a = adder(); a.next(); probe(a.next(10).value); probe(a.next(15).value); probe(a.next().value);",
        &w2[0], 3, "generator two-way");

    // yield* delegation: outer yields 0,1,2,3 -> sum 6, count 4
    f64[2] w3 = { 6.0, 4.0 };
    check_probes("function* inner() { yield 1; yield 2; } function* outer() { yield 0; yield* inner(); yield 3; } let s = 0; let c = 0; for (const v of outer()) { s += v; c++; } probe(s); probe(c);",
        &w3[0], 2, "yield delegation");

    // generator throw and try/finally inside
    f64[2] w4 = { 5.0, 1.0 };
    check_probes("function* g() { try { yield 1; yield 2; } catch (e) { probe(5); yield 99; } } const it = g(); it.next(); const r = it.throw('x'); probe(r.value === 99 ? 1 : 0);",
        &w4[0], 2, "generator throw");

    // symbols as property keys, typeof, custom iterator
    f64[5] w5 = { 42.0, 1.0, 1.0, 6.0, 1.0 };
    check_probes("const s = Symbol('k'); const o = { [s]: 42, a: 1 }; probe(o[s]); probe(Object.keys(o).length); probe(typeof s === 'symbol' ? 1 : 0); const range = { from: 1, to: 3, [Symbol.iterator]() { let n = this.from; const last = this.to; return { next() { return n <= last ? { value: n++, done: false } : { value: undefined, done: true }; } }; } }; let sum = 0; for (const v of range) { sum += v; } probe(sum); probe([...range].length === 3 ? 1 : 0);",
        &w5[0], 5, "symbols and custom iterables");

    // promise ordering: sync 1,2; then A(3) schedules B; C(22) runs
    // before B(11) because chaining defers B by one microtask turn
    f64[5] w6 = { 1.0, 2.0, 3.0, 22.0, 11.0 };
    check_probes("probe(1); Promise.resolve(10).then(v => { probe(3); return v + 1; }).then(v => probe(v)); probe(2); Promise.resolve(20).then(v => probe(v + 2));",
        &w6[0], 5, "promise ordering");

    // Promise.all and race
    f64[3] w7 = { 6.0, 3.0, 1.0 };
    check_probes("Promise.all([Promise.resolve(1), 2, Promise.resolve(3)]).then(rs => { probe(rs[0] + rs[1] + rs[2]); probe(rs.length); }); Promise.race([Promise.resolve('a'), Promise.resolve('b')]).then(v => probe(v === 'a' ? 1 : 0));",
        &w7[0], 3, "promise combinators");

    // async/await: values, promises, sequential
    f64[3] w8 = { 42.0, 30.0, 6.0 };
    check_probes("async function av() { return 42; } av().then(v => probe(v)); async function seq() { const a = await Promise.resolve(10); const b = await 20; return a + b; } seq().then(v => probe(v)); async function loop() { let t = 0; for (let i = 1; i <= 3; i++) { t += await Promise.resolve(i); } return t; } loop().then(v => probe(v));",
        &w8[0], 3, "async await");

    // async try/catch around await, rejection handling
    f64[3] w9 = { 1.0, 7.0, 99.0 };
    check_probes("async function f() { try { await Promise.reject(new Error('boom')); probe(0); } catch (e) { probe(e instanceof Error ? 1 : 0); return 99; } } f().then(v => probe(v)); Promise.reject('x').catch(e => probe(7));",
        &w9[0], 3, "async rejection");

    // timer ordering by delay (virtual time)
    f64[4] w10 = { 1.0, 2.0, 3.0, 4.0 };
    check_probes("setTimeout(() => probe(3), 20); setTimeout(() => probe(2), 10); setTimeout(() => probe(4), 20); probe(1);",
        &w10[0], 4, "timer ordering");

    // microtasks drain before timers
    f64[3] w11 = { 1.0, 2.0, 3.0 };
    check_probes("setTimeout(() => probe(3), 0); Promise.resolve().then(() => probe(2)); probe(1);",
        &w11[0], 3, "microtask before timer");

    // clearTimeout
    f64[2] w12 = { 1.0, 5.0 };
    check_probes("const id = setTimeout(() => probe(99), 10); clearTimeout(id); setTimeout(() => probe(5), 20); probe(1);",
        &w12[0], 2, "clear timeout");

    // a throw in a .then rejects the derived promise; with no handler it
    // is an unhandled rejection, reported and exit 1 (matching Node)
    check_eq(run_snippet("Promise.resolve().then(() => { throw new Error('unhandled'); });", false), 1, "unhandled rejection exits 1");
    // the same rejection, handled by a .catch, completes cleanly
    check_eq(run_snippet("Promise.resolve().then(() => { throw new Error('x'); }).catch(() => {});", false), 0, "handled rejection exits 0");
    // a throw in a timer callback is an uncaught exception
    check_eq(run_snippet("setTimeout(() => { throw new Error('boom'); }, 0);", false), 1, "throw in timer exits 1");

    // GC stress across suspension/resumption
    {
        g_probe_n = 0;
        VM m;
        vm_init(&m);
        builtins_install(&m);
        m.heap.stress = true;
        vm_set_global(&m, "probe", vm_make_native(&m, &probe_native, "probe"));
        i32 st = vm_run_source(&m,
            "function* nums() { for (let i = 0; i < 20; i++) { yield i * i; } } let s = 0; for (const v of nums()) { s += v; } probe(s); async function chain() { let t = 0; for (let i = 0; i < 10; i++) { t += await Promise.resolve(i); } return t; } chain().then(v => probe(v));",
            "stress");
        vm_destroy(&m);
        check_eq(st, 0, "async gc stress");
        check_eq(g_probe_n, 2, "async gc stress probes");
        check(js_to_number(g_probes[0]) == 2470.0, "generator sum of squares");
        check(js_to_number(g_probes[1]) == 45.0, "async loop sum");
    }

    return check_done("test_async");
}

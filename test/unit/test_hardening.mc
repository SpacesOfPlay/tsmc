// test_hardening.mc — resource limits and pathological inputs must
// produce clean errors or bounded results, never a crash.

import str;
import "../helpers/check.mc";
import "../../src/value.mc";
import "../../src/object.mc";
import "../../src/vm.mc";
import "../../src/builtins.mc";

Value[16] g_probes;
i32 g_probe_n = 0;

Value probe_native(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    if argc > 0 && g_probe_n < 16 {
        g_probes[g_probe_n] = *(args);
        g_probe_n++;
    }
    return value_undefined();
}

i32 run(str src) {
    g_probe_n = 0;
    VM m;
    vm_init(&m);
    builtins_install(&m);
    vm_set_global(&m, "probe", vm_make_native(&m, &probe_native, "probe"));
    i32 st = vm_run_source(&m, src, "harden");
    vm_destroy(&m);
    return st;
}

f64 run1(str src) {
    run(src);
    if g_probe_n < 1 { return 0.0 / 0.0; }
    return js_to_number(g_probes[0]);
}

i32 main() {
    // runaway recursion -> RangeError caught in-script (exit 0)
    check_eq(run("function r(n){return r(n+1);} try{r(0);}catch(e){probe(e instanceof RangeError?1:0);}"),
        0, "runaway recursion caught");
    check(run1("function r(n){return r(n+1);} let ok=0; try{r(0);}catch(e){ok=e instanceof RangeError?1:0;} probe(ok);") == 1.0,
        "recursion throws RangeError");

    // legitimate deep recursion succeeds
    check(run1("function s(n){return n<=0?0:n+s(n-1);} probe(s(2000));") == 2001000.0,
        "deep recursion 2000 ok");

    // native re-entry (callback recursion) capped, still RangeError
    check(run1("function f(n){return [1].map(()=>n<=0?0:f(n-1))[0];} let ok=0; try{f(100000);}catch(e){ok=e instanceof RangeError?1:0;} probe(ok);") == 1.0,
        "native reentry capped");

    // wide object: property index correctness at scale
    check(run1("const o={}; for(let i=0;i<1000;i++){o['k'+i]=i;} let s=0; for(let i=0;i<1000;i++){s+=o['k'+i];} probe(s);") == 499500.0,
        "wide object 1000 keys");
    check(run1("const o={}; for(let i=0;i<500;i++){o['k'+i]=i;} for(let i=0;i<250;i++){delete o['k'+i];} let s=0; for(let i=0;i<500;i++){if(o['k'+i]!==undefined)s+=o['k'+i];} probe(s);") == 93625.0,
        "wide object with deletions");

    // deep data nesting via JSON round trip
    check(run1("let s='0'; for(let i=0;i<60;i++){s='['+s+']';} const a=JSON.parse(s); let d=0,c=a; while(Array.isArray(c)){d++;c=c[0];} probe(d);") == 60.0,
        "deep json nesting");

    // long string building stays correct
    check(run1("let s=''; for(let i=0;i<5000;i++){s+='x';} probe(s.length);") == 5000.0,
        "long string build");

    // large array
    check(run1("const a=[]; for(let i=0;i<10000;i++){a.push(i);} probe(a.reduce((x,y)=>x+y,0));") == 49995000.0,
        "large array reduce");

    // sustained allocation under the real (non-stress) collector
    check(run1("let last=null; for(let i=0;i<50000;i++){last={v:i,prev:last};} let n=0,c=last; while(c!==null){n++;c=c.prev;} probe(n);") == 50000.0,
        "sustained allocation");

    // huge numeric literal parses to a finite double
    check(run1("probe(1e308 < Infinity ? 1 : 0);") == 1.0, "huge literal finite");

    // pathological regex bounded by the step limit (no hang): a.*a.*b
    // against a long non-matching string returns false, doesn't spin
    check_eq(run("const re=/a.*a.*a.*b/; const s='a'.repeat(40); probe(re.test(s+'c')?1:0);"),
        0, "regex step limit no hang");

    // uncaught throw exits 1
    check_eq(run("throw new Error('x');"), 1, "uncaught exits 1");
    // compile error exits 2
    check_eq(run("class A { get [1]() { return 2; } }"), 2, "unsupported exits 2");

    return check_done("test_hardening");
}

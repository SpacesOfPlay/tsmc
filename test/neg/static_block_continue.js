// expect: continue
l: while (false) { class C { static { continue l; } } }

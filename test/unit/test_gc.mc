// test_gc.mc — mark-sweep: garbage dies, rooted graphs survive intact.

import vec;
import str;
import "../helpers/check.mc";
import "../../src/value.mc";
import "../../src/gc.mc";

i32 main() {
    GcHeap h;
    gc_init(&h);

    // unrooted cells are collected
    gc_new_string(&h, "hello");
    gc_new_string(&h, "world");
    check_eq_i64(h.n_cells, 2, "cells allocated");
    gc_collect(&h);
    check_eq_i64(h.n_cells, 0, "garbage collected");
    check_eq_i64(h.bytes_live, 0, "no live bytes");

    // rooted cell survives, contents intact
    GcString* keep = gc_new_string(&h, "keep");
    gc_root(&h, value_cell(&keep.head));
    gc_new_string(&h, "drop");
    gc_collect(&h);
    check_eq_i64(h.n_cells, 1, "rooted survives");
    check(str_equal(gc_string_view(keep), "keep"), "contents intact");

    // nested graph: root -> pair -> (string, pair -> string)
    i32 base = gc_root_mark(&h);
    GcString* s1 = gc_new_string(&h, "leaf1");
    gc_root(&h, value_cell(&s1.head));
    GcString* s2 = gc_new_string(&h, "leaf2");
    gc_root(&h, value_cell(&s2.head));
    GcPair* inner = gc_new_pair(&h, value_cell(&s2.head), value_undefined());
    gc_root(&h, value_cell(&inner.head));
    GcPair* outer = gc_new_pair(&h, value_cell(&s1.head), value_cell(&inner.head));
    gc_root_reset(&h, base);
    gc_root(&h, value_cell(&outer.head));
    gc_collect(&h);
    check_eq_i64(h.n_cells, 5, "graph fully traced");   // keep + 2 strings + 2 pairs
    check(str_equal(gc_string_view(s1), "leaf1"), "leaf1 intact");
    check(str_equal(gc_string_view(s2), "leaf2"), "leaf2 intact");
    gc_root_reset(&h, base);
    gc_collect(&h);
    check_eq_i64(h.n_cells, 1, "graph released");

    // unrooted cycle is collected
    GcPair* a = gc_new_pair(&h, value_undefined(), value_undefined());
    GcPair* b = gc_new_pair(&h, value_cell(&a.head), value_undefined());
    a.a = value_cell(&b.head);
    gc_collect(&h);
    check_eq_i64(h.n_cells, 1, "cycle collected");

    // stress mode: every allocation collects; a rooted list survives
    h.stress = true;
    Value chain = value_undefined();
    for i32 i = 0; i < 100; i++ {
        gc_root(&h, chain);
        GcPair* p = gc_new_pair(&h, chain, value_int(i));
        gc_root_reset(&h, gc_root_mark(&h) - 1);
        chain = value_cell(&p.head);
    }
    gc_root(&h, chain);
    gc_collect(&h);
    check_eq_i64(h.n_cells, 101, "stress list survives");   // keep + 100 pairs

    // walk the list: values 99..0
    bool walk_ok = true;
    Value cur = chain;
    for i32 i = 99; i >= 0; i-- {
        if !value_is_cell(cur) { walk_ok = false; break; }
        GcPair* p = cast(GcPair*, value_as_cell(cur));
        if !value_is_int(p.b) || value_as_int(p.b) != i { walk_ok = false; break; }
        cur = p.a;
    }
    check(walk_ok && value_is_undefined(cur), "stress list contents intact");
    h.stress = false;

    check(h.n_collections > 100, "stress collected per alloc");

    gc_destroy(&h);
    check_eq_i64(h.n_cells, 0, "destroy frees all");
    return check_done("test_gc");
}

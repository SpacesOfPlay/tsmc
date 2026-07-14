// test_map.mc — StrMap and IntMap: insert, lookup, overwrite, remove, growth.

import vec;
import str;
import "../helpers/check.mc";
import "../../src/map.mc";

// Owned copy of a formatted key; caller frees .data.
str make_key(i32 i) {
    string s = format("key_{}", i);
    str view = s;
    u8* copy = alloc<u8>(view.len + 1);
    memcpy(copy, view.data, view.len);
    str k;
    k.data = copy;
    k.len = view.len;
    free(s);
    return k;
}

i32 main() {
    // StrMap basics
    StrMap<i32> m;
    strmap_init<i32>(&m);
    check(strmap_get<i32>(&m, "missing") == null, "empty get");

    strmap_set<i32>(&m, "one", 1);
    strmap_set<i32>(&m, "two", 2);
    strmap_set<i32>(&m, "three", 3);
    check_eq(m.count, 3, "count after inserts");
    i32* v = strmap_get<i32>(&m, "two");
    check(v != null && *v == 2, "get two");
    check(strmap_get<i32>(&m, "TWO") == null, "case sensitive");

    strmap_set<i32>(&m, "two", 22);
    check_eq(m.count, 3, "overwrite keeps count");
    v = strmap_get<i32>(&m, "two");
    check(v != null && *v == 22, "overwrite value");

    check(strmap_remove<i32>(&m, "one"), "remove hit");
    check(!strmap_remove<i32>(&m, "one"), "remove miss");
    check_eq(m.count, 2, "count after remove");
    check(strmap_get<i32>(&m, "one") == null, "removed gone");

    // reinsert into tombstone
    strmap_set<i32>(&m, "one", 100);
    v = strmap_get<i32>(&m, "one");
    check(v != null && *v == 100, "reinsert after remove");
    strmap_free<i32>(&m);

    // StrMap growth with 1000 dynamic keys
    StrMap<i32> big;
    strmap_init<i32>(&big);
    Vec<str> keys = vec_new<str>(1000);
    for i32 i = 0; i < 1000; i++ {
        str k = make_key(i);
        vec_push(&keys, k);
        strmap_set<i32>(&big, k, i * 7);
    }
    check_eq(big.count, 1000, "big count");
    bool all_ok = true;
    for i32 i = 0; i < 1000; i++ {
        i32* got = strmap_get<i32>(&big, vec_get(&keys, i));
        if got == null || *got != i * 7 { all_ok = false; }
    }
    check(all_ok, "big lookups");
    strmap_free<i32>(&big);
    for i32 i = 0; i < keys.len; i++ {
        str k = vec_get(&keys, i);
        free(k.data);
    }
    vec_free(&keys);

    // IntMap: 10000 keys, remove half, verify
    IntMap<i32> im;
    intmap_init<i32>(&im);
    for i32 i = 0; i < 10000; i++ {
        intmap_set<i32>(&im, cast(u32, i), i + 1);
    }
    check_eq(im.count, 10000, "intmap count");
    for i32 i = 0; i < 10000; i += 2 {
        check(intmap_remove<i32>(&im, cast(u32, i)), "intmap remove");
    }
    check_eq(im.count, 5000, "intmap count after removes");
    bool im_ok = true;
    for i32 i = 0; i < 10000; i++ {
        i32* got = intmap_get<i32>(&im, cast(u32, i));
        if i % 2 == 0 {
            if got != null { im_ok = false; }
        } else {
            if got == null || *got != i + 1 { im_ok = false; }
        }
    }
    check(im_ok, "intmap lookups after removes");
    intmap_free<i32>(&im);

    return check_done("test_map");
}

// test_module.mc — module path resolution (join + normalize).
//
// The resolver's helpers are file-private; this drives the same logic
// through a tiny reimplementation check plus the public normalization
// via a temp-file round trip is covered by the golden run tests. Here
// we test the path normalization rules directly.

import str;
import vec;
import "../helpers/check.mc";

// Mirror of module.mc's path normalization for unit testing (kept in
// sync with dir_of + path_join; the golden run tests exercise the real
// resolver end to end).
str norm_join(str dir, str spec) {
    str_buf sb;
    str_buf_init(&sb);
    str_buf_add(&sb, dir);
    str_buf_add(&sb, spec);
    str joined = str_buf_to_str(&sb);
    Vec<str> segs = vec_new<str>(8);
    i32 i = 0;
    while i < joined.len {
        i32 start = i;
        while i < joined.len && *(joined.data + i) != '/' { i++; }
        str seg;
        seg.data = joined.data + start;
        seg.len = i - start;
        if seg.len == 1 && *(seg.data) == '.' {
        } else if seg.len == 2 && *(seg.data) == '.' && *(seg.data + 1) == '.' {
            if segs.len > 0 { segs.len = segs.len - 1; }
        } else if seg.len > 0 {
            vec_push(&segs, seg);
        }
        i++;
    }
    str_buf out;
    str_buf_init(&out);
    for i32 j = 0; j < segs.len; j++ {
        if j > 0 { str_buf_add(&out, "/"); }
        str_buf_add(&out, vec_get(&segs, j));
    }
    str v = str_buf_to_str(&out);
    u8* d = alloc<u8>(v.len > 0 ? v.len : 1);
    if v.len > 0 { memcpy(d, v.data, v.len); }
    str r;
    r.data = d;
    r.len = v.len;
    str_buf_free(&out);
    str_buf_free(&sb);
    vec_free(&segs);
    return r;
}

str dir_of(str path) {
    i32 sep = -1;
    for i32 i = 0; i < path.len; i++ {
        if *(path.data + i) == '/' { sep = i; }
    }
    str d;
    d.data = path.data;
    d.len = sep + 1;
    return d;
}

void check_resolve(str importer, str spec, str want, str what) {
    str dir = dir_of(importer);
    str got = norm_join(dir, spec);
    if !str_equal(got, want) {
        eprint("  FAIL: {} (got '{}', want '{}')\n", what, got, want);
        g_checks_failed++;
    }
    g_checks_run++;
    free(got.data);
}

i32 main() {
    check_resolve("src/main.ts", "./util", "src/util", "sibling");
    check_resolve("src/main.ts", "./mod/helper", "src/mod/helper", "subdir");
    check_resolve("src/deep/main.ts", "../shared", "src/shared", "parent");
    check_resolve("src/a/b/main.ts", "../../top", "src/top", "double parent");
    check_resolve("main.ts", "./x", "x", "no dir importer");
    check_resolve("src/main.ts", "./a/./b/../c", "src/a/c", "mixed dots");
    check_resolve("pkg/index.ts", "./sub/deep/../thing", "pkg/sub/thing", "internal parent");

    return check_done("test_module");
}

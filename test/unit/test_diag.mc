// test_diag.mc — diagnostic list and line/column derivation.

import vec;
import str;
import "../helpers/check.mc";
import "../../src/diag.mc";

i32 main() {
    str src = "let x = 1;\nlet y =;\nx + y;\n";

    // line/col: offset 0 is 1:1; offsets past newlines advance lines
    LineCol lc = diag_line_col(src, 0);
    check_eq(lc.line, 1, "start line");
    check_eq(lc.col, 1, "start col");
    lc = diag_line_col(src, 11);        // first char of line 2
    check_eq(lc.line, 2, "line 2");
    check_eq(lc.col, 1, "line 2 col 1");
    lc = diag_line_col(src, 18);        // the ';' in "let y =;"
    check_eq(lc.line, 2, "line 2 again");
    check_eq(lc.col, 8, "col of ;");
    lc = diag_line_col(src, 1000);      // clamped to end of source
    check_eq(lc.line, 4, "offset past end clamps");

    DiagList d;
    diags_init(&d);
    check_eq(d.n_errors, 0, "starts clean");

    string msg = format("unexpected token at offset {}", 18);
    diag_add(&d, DIAG_ERROR, Span{18, 19}, msg);
    free(msg);
    diag_add(&d, DIAG_WARNING, Span{0, 3}, "unused variable");
    diag_add(&d, DIAG_NOTE, Span{22, 23}, "declared here");

    check_eq(d.list.len, 3, "three diags");
    check_eq(d.n_errors, 1, "one error");

    // the list owns message copies
    Diag first = vec_get(&d.list, 0);
    check(str_equal(first.message, "unexpected token at offset 18"), "message copied");

    diags_free(&d);
    return check_done("test_diag");
}

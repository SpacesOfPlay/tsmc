// diag.mc — diagnostics with source spans.
//
// All user-facing errors flow through a DiagList. Spans are byte
// offsets into the source; line and column are derived on demand.

import vec;
import str;

enum DiagSeverity { DIAG_ERROR, DIAG_WARNING, DIAG_NOTE }

struct Span {
    i32 start;
    i32 end;
}

struct Diag {
    i32 severity;
    Span span;
    str message;    // list-owned copy
}

struct DiagList {
    Vec<Diag> list;
    i32 n_errors;
    i32 muted;          // > 0 while parsing speculatively
    i32 n_suppressed;   // adds dropped while muted
}

void diags_init(DiagList* d) {
    vec_init<Diag>(&d.list, 8);
    d.n_errors = 0;
    d.muted = 0;
    d.n_suppressed = 0;
}

void diags_mute(DiagList* d) {
    d.muted++;
}

void diags_unmute(DiagList* d) {
    d.muted--;
}

void diags_free(DiagList* d) {
    for i32 i = 0; i < d.list.len; i++ {
        Diag dg = vec_get(&d.list, i);
        free(dg.message.data);
    }
    vec_free(&d.list);
    d.n_errors = 0;
}

// The message is copied; callers keep ownership of theirs.
void diag_add(DiagList* d, i32 severity, Span span, str message) {
    if d.muted > 0 {
        d.n_suppressed++;
        return;
    }
    u8* copy = alloc<u8>(message.len + 1);
    if message.len > 0 { memcpy(copy, message.data, message.len); }
    Diag dg;
    dg.severity = severity;
    dg.span = span;
    dg.message.data = copy;
    dg.message.len = message.len;
    vec_push(&d.list, dg);
    if severity == DIAG_ERROR { d.n_errors++; }
}

struct LineCol {
    i32 line;   // 1-based
    i32 col;    // 1-based, byte column
}

LineCol diag_line_col(str src, i32 offset) {
    LineCol lc = LineCol{1, 1};
    for i32 i = 0; i < offset && i < src.len; i++ {
        if *(src.data + i) == '\n' {
            lc.line++;
            lc.col = 1;
        } else {
            lc.col++;
        }
    }
    return lc;
}

void diags_print(DiagList* d, str src_name, str src) {
    for i32 i = 0; i < d.list.len; i++ {
        Diag dg = vec_get(&d.list, i);
        LineCol lc = diag_line_col(src, dg.span.start);
        str sev = "error";
        if dg.severity == DIAG_WARNING { sev = "warning"; }
        if dg.severity == DIAG_NOTE { sev = "note"; }
        eprint("{}:{}:{}: {}: {}\n", src_name, lc.line, lc.col, sev, dg.message);
    }
}

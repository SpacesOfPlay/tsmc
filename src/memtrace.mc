// memtrace.mc -- a log of the heap's object traffic, for a cache model.
//
// A build with TSMC_MEMTRACE defined calls mt_ev from the allocator, the
// sweep, the property tables, the inline cache's own-slot hits and the
// marker; with TSMC_MEMTRACE set in the environment to a path, the events
// go there as 32-byte records, which tools/memsim.mc replays through a
// model of the caches under today's layout and under shapes. A default
// build has none of the calls.

import file;

const u32 MT_HEADER = 1;     // a: the props offset in an object, b: in a function, c: in a native
const u32 MT_ALLOC = 2;      // a: cell, c: block bytes, d: kind
const u32 MT_FREE = 3;       // a: cell
const u32 MT_OBJECT = 4;     // a: object, c: inline room (entries)
const u32 MT_GROW = 5;       // a: table, b: new items, c: new cap
const u32 MT_ADD = 6;        // a: table, c: key, d: flags
const u32 MT_REMOVE = 7;     // a: table, c: key, d: position it had
const u32 MT_FLAGS = 8;      // a: table, c: key, d: new flags
const u32 MT_READ = 9;       // a: table, b: the value's cell or 0, c: slot
const u32 MT_WRITE = 10;     // a: table, b: the old value's cell or 0, c: slot
const u32 MT_MARK = 11;      // a: cell
const u32 MT_TRACE = 12;     // a: table, c: entries
const u32 MT_PREAD = 13;     // a: the receiver's table (0: a kind's prototype), b: the prototype's, e: the value's cell or 0, c: slot

struct MtRec {
    u64 a;
    u64 b;
    u64 e;
    u32 c;
    u32 t;   // the type, d above it
}

const i32 MT_BUF = 65536;

private i32 g_mt_state = 0;   // 0 not looked at, 1 on, 2 off
private i64 g_mt_fd = -1;
private MtRec* g_mt_buf = null;
private i32 g_mt_n = 0;

private void mt_flush() {
    if g_mt_n == 0 { return; }
    i64 bytes = cast(i64, g_mt_n) * sizeof(MtRec);
    u8* p = cast(u8*, g_mt_buf);
    i64 done = 0;
    while done < bytes {
        i64 want = bytes - done;
        if want > 1048576 { want = 1048576; }
        i32 n = write(g_mt_fd, p + done, cast(i32, want));
        if n <= 0 { break; }
        done = done + n;
    }
    g_mt_n = 0;
}

private bool mt_start() {
    string path = env_get("TSMC_MEMTRACE");
    if path.len == 0 { g_mt_state = 2; return false; }
    u8* cp = str_to_cstr(path);
    g_mt_fd = open(cp, 1);
    free(cp);
    free(path);
    if g_mt_fd == -1 { g_mt_state = 2; return false; }
    g_mt_buf = alloc<MtRec>(MT_BUF);
    g_mt_state = 1;
    return true;
}

bool mt_on() {
    if g_mt_state == 0 { return mt_start(); }
    return g_mt_state == 1;
}

void mt_ev(u32 t, u64 a, u64 b, u32 c, u32 d) { mt_ev3(t, a, b, 0, c, d); }

void mt_ev3(u32 t, u64 a, u64 b, u64 e, u32 c, u32 d) {
    if g_mt_state != 1 && !mt_on() { return; }
    MtRec* r = g_mt_buf + g_mt_n;
    r.a = a;
    r.b = b;
    r.e = e;
    r.c = c;
    r.t = t | (d << 8);
    g_mt_n++;
    if g_mt_n == MT_BUF { mt_flush(); }
}

// The rest of the log written and the file closed, at the end of a run.
void mt_close() {
    if g_mt_state != 1 { return; }
    mt_flush();
    close(g_mt_fd);
    g_mt_state = 2;
}

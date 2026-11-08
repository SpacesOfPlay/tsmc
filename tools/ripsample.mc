// ripsample: the main thread's instruction pointer of a program, sampled
// while it runs, as a histogram of addresses. Windows x64.
//
//   ripsample <out.txt> <interval_us> <exe> [args...]
//
// Starts the program, then every `interval_us` suspends its main thread,
// reads RIP and resumes it, until the program exits. The addresses are
// written as the program's image sees them (the module's load address
// taken out, the file's image base added), one `addr count` per line in
// decimal, so that `minc-dbg --disasm` of the same binary maps them to
// source lines and `tools/ripmap.py` to the interpreter's cases. A
// suspend and resume costs the program about 10 us; at 250 us that is
// 4% of its time, spread evenly. Only the main thread is seen: a loader
// or compile thread of brmc's is outside the histogram.
import str;
import file;

when os(windows) {

private {
    struct StartupInfo {
        u32 cb;
        u8* reserved;
        u8* desktop;
        u8* title;
        u32 dw_x;
        u32 dw_y;
        u32 dw_x_size;
        u32 dw_y_size;
        u32 dw_x_count_chars;
        u32 dw_y_count_chars;
        u32 fill_attribute;
        u32 flags;
        u16 show_window;
        u16 cb_reserved2;
        u8* reserved2;
        i64 h_std_input;
        i64 h_std_output;
        i64 h_std_error;
    }

    struct ProcessInfo {
        i64 h_process;
        i64 h_thread;
        u32 process_id;
        u32 thread_id;
    }

    extern "kernel32.dll" {
        bool CreateProcessW(u16* app, u16* cmd, void* pa, void* ta, bool inherit, i32 flags, void* env, u16* dir, StartupInfo* si, ProcessInfo* pi);
        i32 MultiByteToWideChar(u32 cp, u32 flags, u8* mb, i32 cb, u16* wc, i32 cc);
        i32 WaitForSingleObject(i64 h, i32 ms);
        bool GetExitCodeProcess(i64 h, i32* code);
        bool CloseHandle(i64 h);
        u32 SuspendThread(i64 h);
        u32 ResumeThread(i64 h);
        bool GetThreadContext(i64 h, u8* ctx);
        bool K32EnumProcessModules(i64 h, void** mods, u32 cb, u32* needed);
        i32 QueryPerformanceCounter(i64* p);
        i32 QueryPerformanceFrequency(i64* p);
        void Sleep(u32 ms);
    }

    const u32 CP_UTF8 = 65001;
    const i32 WAIT_TIMEOUT = 258;
    // CONTEXT on x64: 1232 bytes, 16-aligned; ContextFlags at 0x30, Rip at 0xf8
    const i32 CONTEXT_SIZE = 1232;
    const i32 CONTEXT_FLAGS_AT = 0x30;
    const i32 CONTEXT_RIP_AT = 0xf8;
    const u32 CONTEXT_CONTROL = 0x100001;

    u16* wide(str s) {
        u8* z = alloc<u8>(cast(i64, s.len) + 1);
        for i32 i = 0; i < s.len; i++ { *(z + i) = *(s.data + i); }
        *(z + s.len) = 0;
        i32 n = MultiByteToWideChar(CP_UTF8, 0, z, -1, null, 0);
        u16* w = alloc<u16>(n);
        ignore MultiByteToWideChar(CP_UTF8, 0, z, -1, w, n);
        free(z);
        return w;
    }

    // Quotes an argument the way CreateProcess's parser undoes it.
    void quote_arg(str_buf* b, str a) {
        bool plain = a.len > 0;
        for i32 i = 0; i < a.len; i++ { u8 c = *(a.data + i); if c == ' ' || c == '"' || c == '\t' { plain = false; } }
        if plain { str_buf_add(b, a); return; }
        str_buf_add(b, "\"");
        for i32 i = 0; i < a.len; i++ {
            u8 c = *(a.data + i);
            if c == '"' { str_buf_add(b, "\\"); }
            str_buf_add(b, str_from(a.data + i, 1));
        }
        str_buf_add(b, "\"");
    }

    // The image base the file was linked at, from its PE header: e_lfanew
    // at 0x3c, the optional header 24 bytes past the signature, ImageBase
    // at its 0x18.
    i64 file_image_base(str path) {
        var fd = file_read(path);
        if fd.data == null || fd.len < 0x200 { return 0x400000; }
        defer free(fd.data);
        i32 lfanew = *cast(i32*, fd.data + 0x3c);
        i64 base = *cast(i64*, fd.data + lfanew + 24 + 0x18);
        return base;
    }

    // The histogram: open addressing on the address above the load base,
    // a million slots, a text section being far smaller than that.
    const i32 SLOTS = 1 << 20;
    struct Hist {
        u32* keys;      // 0xFFFFFFFF is empty
        i64* counts;
        i32 used;
    }

    void hist_add(Hist* h, u32 key) {
        u32 i = (key * 2654435761) & cast(u32, SLOTS - 1);
        while true {
            if h.keys[i] == key { h.counts[i]++; return; }
            if h.keys[i] == 0xFFFFFFFF { h.keys[i] = key; h.counts[i] = 1; h.used++; return; }
            i = (i + 1) & cast(u32, SLOTS - 1);
        }
    }
}

i32 main() {
    if get_argc() < 4 {
        eprint("usage: ripsample <out.txt> <interval_us> <exe> [args...]\n");
        return 2;
    }
    str out_path = str_from_cstr(get_arg(1));
    i64 interval_us = 0;
    str iv = str_from_cstr(get_arg(2));
    for i32 i = 0; i < iv.len; i++ { u8 c = *(iv.data + i); if c >= '0' && c <= '9' { interval_us = interval_us * 10 + cast(i64, c - '0'); } }
    if interval_us < 20 { interval_us = 20; }
    str exe = str_from_cstr(get_arg(3));

    str_buf cl;
    str_buf_init(&cl);
    for i32 i = 3; i < get_argc(); i++ {
        if i > 3 { str_buf_add(&cl, " "); }
        quote_arg(&cl, str_from_cstr(get_arg(i)));
    }
    u16* wcl = wide(str_buf_to_str(&cl));

    StartupInfo si = StartupInfo{};
    si.cb = cast(u32, sizeof(StartupInfo));
    ProcessInfo pi = ProcessInfo{};
    if !CreateProcessW(null, wcl, null, null, true, 0, null, null, &si, &pi) {
        eprint("ripsample: cannot start {}\n", exe);
        return 2;
    }

    // the module's load address, once the loader has it in place
    void* mod = null;
    for i32 tries = 0; tries < 200 && mod == null; tries++ {
        void*[1] mods;
        u32 needed = 0;
        if K32EnumProcessModules(pi.h_process, &mods[0], 8, &needed) && needed >= 8 { mod = mods[0]; }
        else { Sleep(5); }
    }
    i64 load_base = cast(i64, mod);
    i64 image_base = file_image_base(exe);

    u8* raw = alloc<u8>(CONTEXT_SIZE + 16);
    u8* ctx = cast(u8*, (cast(i64, raw) + 15) & ~cast(i64, 15));

    Hist h;
    h.keys = alloc<u32>(SLOTS);
    h.counts = alloc<i64>(SLOTS);
    h.used = 0;
    for i32 i = 0; i < SLOTS; i++ { h.keys[i] = 0xFFFFFFFF; }

    i64 samples = 0;
    i64 failed = 0;
    i64 f = 0;
    ignore QueryPerformanceFrequency(&f);
    i64 step = f * interval_us / 1000000;
    i64 next = 0;
    ignore QueryPerformanceCounter(&next);
    while WaitForSingleObject(pi.h_process, 0) == WAIT_TIMEOUT {
        i64 now = 0;
        ignore QueryPerformanceCounter(&now);
        if now < next {
            if next - now > f / 2000 { Sleep(0); }
            continue;
        }
        next = now + step;
        if SuspendThread(pi.h_thread) == 0xFFFFFFFF { failed++; continue; }
        for i32 k = 0; k < CONTEXT_SIZE; k++ { *(ctx + k) = 0; }
        *cast(u32*, ctx + CONTEXT_FLAGS_AT) = CONTEXT_CONTROL;
        bool ok = GetThreadContext(pi.h_thread, ctx);
        u64 rip = *cast(u64*, ctx + CONTEXT_RIP_AT);
        ignore ResumeThread(pi.h_thread);
        if !ok { failed++; continue; }
        i64 rel = cast(i64, rip) - load_base;
        u32 key = rel >= 0 && rel < 0x7ffffff0 ? cast(u32, rel) : 0xFFFFFFF0;
        hist_add(&h, key);
        samples++;
    }
    i32 code = 0;
    ignore GetExitCodeProcess(pi.h_process, &code);

    // the histogram out, addresses as the image sees them
    str_buf o;
    str_buf_init(&o);
    using string head = format("# ripsample: {} samples, {} failed, interval {} us, load base {}, image base {}, exit {}\n", samples, failed, interval_us, load_base, image_base, code);
    str_buf_add(&o, str_from(head.data, head.len));
    for i32 i = 0; i < SLOTS; i++ {
        u32 key = h.keys[i];
        if key == 0xFFFFFFFF { continue; }
        if key == 0xFFFFFFF0 {
            using string line = format("outside {}\n", h.counts[i]);
            str_buf_add(&o, str_from(line.data, line.len));
        } else {
            using string line = format("{} {}\n", image_base + cast(i64, key), h.counts[i]);
            str_buf_add(&o, str_from(line.data, line.len));
        }
    }
    FileData fd = FileData{ .data = o.data, .len = o.len };
    if !file_write(out_path, fd) { eprint("ripsample: cannot write {}\n", out_path); return 2; }
    eprint("ripsample: {} samples ({} failed) to {}\n", samples, failed, out_path);
    ignore CloseHandle(pi.h_thread);
    ignore CloseHandle(pi.h_process);
    return code;
}

}
else {
    i32 main() {
        eprint("ripsample: Windows x64 only\n");
        return 2;
    }
}

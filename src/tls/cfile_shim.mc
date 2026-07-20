// Imports added on export so this module resolves standalone (LSP).
import cstdlib_shim;

// cfile_shim — directory/stat/sleep externs. Buffered I/O is in
// cstdlib_shim.

when os(windows) {
    extern "msvcrt.dll" {
        i64 _findfirst(u8* spec, void* finddata);
        i32 _findnext(i64 handle, void* finddata);
        i32 _findclose(i64 handle);
        i32 _access(u8* path, i32 mode);
        i32 _chdir(u8* path);
        i32 _mkdir(u8* path);
        u8* _getcwd(u8* buf, i32 size);
        i32 fprintf(void* stream, u8* fmt, ...);
        i32 system(u8* cmd);
    }
    extern "kernel32.dll" {
        void Sleep(u32 ms);
        u32 GetModuleFileNameA(void* mod, u8* name, u32 size);
    }
    extern "winmm.dll" {
        u32 timeBeginPeriod(u32 uPeriod);
        u32 timeEndPeriod(u32 uPeriod);
    }
    // u64 → u32 Sleep wrapper.
    void rl_sleep_u64(u64 ms) { Sleep(cast(u32, ms)); }
    // POSIX-name file ops: Windows ships only the _-prefixed msvcrt variants,
    // so the POSIX spellings are stubs here (real on the linux/macOS arms,
    // stubbed on wasm below).
    i32 access(u8* path, i32 mode) { return 0 - 1; }
    u8* getcwd(u8* buf, u64 size) { return null; }
    i32 chdir(u8* path) { return 0 - 1; }
    i32 mkdir(u8* path, u32 mode) { return 0 - 1; }
    i64 readlink(u8* path, u8* buf, u64 bufsiz) { return 0 - 1; }
}
when os(linux) || os(macos) || os(ios) {
    void rl_sleep_u64(u64 ms) { }
}
// timespec/dirent/DIR passed as void* so import order does not matter.
when os(linux) {
    extern "libc.so.6" {
        i32 access(u8* path, i32 mode);
        i32 chdir(u8* path);
        i32 mkdir(u8* path, u32 mode);
        u8* getcwd(u8* buf, u64 size);
        i32 fprintf(void* stream, u8* fmt, ...);
        i32 system(u8* cmd);
        i32 nanosleep(void* req, void* rem);
        i32 clock_gettime(i32 clk_id, void* tp);
        i64 readlink(u8* path, u8* buf, u64 bufsiz);
        void* opendir(u8* name);
        void* readdir(void* dir);
        i32 closedir(void* dir);
    }
}
when os(macos) || os(ios) {
    extern "libSystem.B.dylib" {
        i32 access(u8* path, i32 mode);
        i32 chdir(u8* path);
        i32 mkdir(u8* path, u32 mode);
        u8* getcwd(u8* buf, u64 size);
        i32 fprintf(void* stream, u8* fmt, ...);
        i32 system(u8* cmd);
        i32 nanosleep(void* req, void* rem);
        i32 clock_gettime(i32 clk_id, void* tp);
        i32 usleep(u32 usec);
        i64 readlink(u8* path, u8* buf, u64 bufsiz);
        i32 _NSGetExecutablePath(u8* buf, u32* bufsize);
        void* opendir(u8* name);
        void* readdir(void* dir);
        i32 closedir(void* dir);
    }
    // f64 → u32 usleep wrapper.
    void rl_usleep(f64 us) { usleep(cast(u32, us)); }
}
// readdir wrapper. Sets d_name to the system dirent's name field
// at the per-platform offset.
when os(linux) || os(macos) || os(ios) {
    struct dirent {
        u8* d_name;
    }
    private { dirent rl_readdir_slot; }
}
when os(linux) {
    // glibc: d_name at offset 19.
    dirent* rl_readdir(void* dir) {
        void* p = readdir(dir);
        if p == null { return null; }
        rl_readdir_slot.d_name = cast(u8*, p) + cast(u64, 19);
        return &rl_readdir_slot;
    }
}
when os(macos) || os(ios) {
    // Darwin 64-bit-inode: d_name at offset 21.
    dirent* rl_readdir(void* dir) {
        void* p = readdir(dir);
        if p == null { return null; }
        rl_readdir_slot.d_name = cast(u8*, p) + cast(u64, 21);
        return &rl_readdir_slot;
    }
}

// wasm: no real filesystem. Directory/path ops are stubs; the JS-host
// VFS (RPW4) serves bundled assets through fopen/fread (cstdlib_shim
// wasm arm). Sleep is a no-op (the RAF loop paces frames).
when os(wasm) {
    i32 access(u8* path, i32 mode) { ignore path; ignore mode; return 0 - 1; }
    i32 chdir(u8* path) { ignore path; return 0 - 1; }
    i32 mkdir(u8* path, u32 mode) { ignore path; ignore mode; return 0 - 1; }
    u8* getcwd(u8* buf, u64 size) {
        if buf != null && size > 0 { *buf = 0; }
        return buf;
    }
    i32 system(u8* cmd) { ignore cmd; return 0 - 1; }
    void* opendir(u8* name) { ignore name; return null; }
    i32 closedir(void* dir) { ignore dir; return 0; }
    i64 readlink(u8* path, u8* buf, u64 bufsiz) { ignore path; ignore buf; ignore bufsiz; return 0 - 1; }

    struct dirent { u8* d_name; }
    dirent* rl_readdir(void* dir) { ignore dir; return null; }

    void rl_sleep_u64(u64 ms) { ignore ms; }
}

// <sys/stat.h> file-type tests.
bool S_ISREG(i32 mode) { return (mode & 0xF000) == 0x8000; }
bool S_ISDIR(i32 mode) { return (mode & 0xF000) == 0x4000; }

// Stub: reports "not a regular file".
i32 rl_fstat(u8* path, void* buf) { return 0 - 1; }

i32 errno = 0;

// Null FILE* sentinels for fflush(stdout/stderr). Output still
// reaches the console. Named c_stdout/c_stderr — transminc maps the
// C names here by default — so they can't shadow minc's stdout()/
// stderr() builtins in units that concatenate this shim.
void* c_stdout = null;
void* c_stderr = null;

// bump.mc — growable bump allocator for parse-phase data.
//
// Allocations are 8-aligned and zeroed. Nothing frees individually;
// bump_destroy releases every chunk at once.

import vec;

type BumpChunk = u8*;

const i32 BUMP_CHUNK_SIZE = 65536;

struct Bump {
    Vec<BumpChunk> chunks;
    u8* cur;
    i32 pos;
    i32 cap;
    i32 first;   // size of the first chunk; later chunks take the default
}

void bump_init(Bump* b) {
    vec_init<BumpChunk>(&b.chunks, 8);
    b.cur = null;
    b.pos = 0;
    b.cap = 0;
    b.first = BUMP_CHUNK_SIZE;
}

// An arena that expects about `bytes` in total starts with a chunk of
// that size, so a small module does not take the default 64 KB.
void bump_init_sized(Bump* b, i32 bytes) {
    bump_init(b);
    if bytes < 2048 { bytes = 2048; }
    if bytes < BUMP_CHUNK_SIZE { b.first = (bytes + 7) / 8 * 8; }
}

void* bump_alloc(Bump* b, i32 size) {
    i32 aligned = (size + 7) / 8 * 8;
    if b.pos + aligned > b.cap {
        i32 csize = b.cur == null ? b.first : BUMP_CHUNK_SIZE;
        if aligned > csize { csize = aligned; }
        b.cur = alloc<u8>(csize);
        vec_push(&b.chunks, b.cur);
        b.pos = 0;
        b.cap = csize;
    }
    u8* p = b.cur + b.pos;
    memset(p, 0, aligned);
    b.pos += aligned;
    return cast(void*, p);
}

void bump_destroy(Bump* b) {
    for i32 i = 0; i < b.chunks.len; i++ {
        free(vec_get(&b.chunks, i));
    }
    vec_free(&b.chunks);
    b.cur = null;
    b.pos = 0;
    b.cap = 0;
}

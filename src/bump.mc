// bump.mc — growable bump allocator for parse-phase data.
//
// Allocations are 8-aligned and zeroed. Nothing frees individually;
// bump_destroy releases every chunk at once.

import vec;

type BumpChunk = u8*;

const i32 BUMP_CHUNK_SIZE = 65536;

struct Bump {
    Vec<BumpChunk> chunks;   // the first chunk, then default-sized ones
    Vec<BumpChunk> big;      // allocations larger than a chunk, one each
    u8* cur;
    i32 pos;
    i32 cap;
    i32 first;   // size of the first chunk; later chunks take the default
}

// Default-sized chunks given back, already cleared, for the next arena on
// the thread: a lazily compiled function is an arena of its own, and a
// page compiles thousands. A chunk is cleared whole when it is made and
// its used part when it comes back, never per allocation, which put a
// library call under every node.
const i32 BUMP_SPARE_MAX = 16;
private threadlocal BumpChunk[16] g_bump_spare;
private threadlocal i32 g_bump_spares = 0;

private u8* bump_chunk(i32 csize) {
    if csize == BUMP_CHUNK_SIZE && g_bump_spares > 0 {
        g_bump_spares--;
        return g_bump_spare[g_bump_spares];
    }
    u8* c = alloc<u8>(csize);
    memset(c, 0, csize);
    return c;
}

void bump_init(Bump* b) {
    vec_init<BumpChunk>(&b.chunks, 8);
    vec_init<BumpChunk>(&b.big, 0);
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
        if aligned > csize {
            u8* own = alloc<u8>(aligned);
            memset(own, 0, aligned);
            vec_push(&b.big, own);
            return cast(void*, own);
        }
        b.cur = bump_chunk(csize);
        vec_push(&b.chunks, b.cur);
        b.pos = 0;
        b.cap = csize;
    }
    u8* p = b.cur + b.pos;
    b.pos += aligned;
    return cast(void*, p);
}

void bump_destroy(Bump* b) {
    for i32 i = 0; i < b.chunks.len; i++ {
        u8* c = vec_get(&b.chunks, i);
        // the last chunk is used up to pos; the ones before it, the
        // default size, may be used to their end
        bool last = i == b.chunks.len - 1;
        bool std = i > 0 || b.first == BUMP_CHUNK_SIZE;
        if std && g_bump_spares < BUMP_SPARE_MAX {
            memset(c, 0, last ? b.pos : BUMP_CHUNK_SIZE);
            g_bump_spare[g_bump_spares] = c;
            g_bump_spares++;
        } else {
            free(c);
        }
    }
    vec_free(&b.chunks);
    for i32 i = 0; i < b.big.len; i++ { free(vec_get(&b.big, i)); }
    vec_free(&b.big);
    b.cur = null;
    b.pos = 0;
    b.cap = 0;
}

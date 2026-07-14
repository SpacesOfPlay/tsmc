// map.mc — open-addressing hash maps: str keys and u32 keys.
//
// Linear probing, power-of-two capacity, tombstones, grow at 75%
// fill. Keys are borrowed and must outlive their entry. Pointers
// from *_get are invalidated by the next insert.

import str;

const i32 SLOT_EMPTY = 0;
const i32 SLOT_USED  = 1;
const i32 SLOT_TOMB  = 2;

u32 map_hash_str(str s) {
    u32 h = 0x811C9DC5;
    for i32 i = 0; i < s.len; i++ {
        h = h ^ cast(u32, *(s.data + i));
        h = h * 0x01000193;
    }
    return h;
}

u32 map_hash_u32(u32 x) {
    u32 h = x * 0x9E3779B9;
    return h ^ (h >> 16);
}

// --- StrMap<V> -----------------------------------------------------

struct StrSlot<V> {
    str key;
    u32 hash;
    i32 state;
    V val;
}

struct StrMap<V> {
    StrSlot<V>* slots;
    i32 cap;
    i32 count;
    i32 filled;   // used + tombstones
}

void strmap_init<V>(StrMap<V>* m) {
    m.slots = null;
    m.cap = 0;
    m.count = 0;
    m.filled = 0;
}

void strmap_free<V>(StrMap<V>* m) {
    if m.slots != null { free(m.slots); }
    strmap_init(m);
}

private void strmap_insert<V>(StrMap<V>* m, str key, u32 h, V val) {
    i32 mask = m.cap - 1;
    i32 i = cast(i32, h) & mask;
    i32 first_tomb = -1;
    while true {
        StrSlot<V>* sl = m.slots + i;
        if sl.state == SLOT_EMPTY {
            StrSlot<V>* dst = sl;
            if first_tomb >= 0 { dst = m.slots + first_tomb; }
            if dst.state == SLOT_EMPTY { m.filled++; }
            dst.key = key;
            dst.hash = h;
            dst.val = val;
            dst.state = SLOT_USED;
            m.count++;
            return;
        }
        if sl.state == SLOT_USED && sl.hash == h && str_equal(sl.key, key) {
            sl.val = val;
            return;
        }
        if sl.state == SLOT_TOMB && first_tomb < 0 { first_tomb = i; }
        i = (i + 1) & mask;
    }
}

private void strmap_grow<V>(StrMap<V>* m) {
    StrSlot<V>* old = m.slots;
    i32 old_cap = m.cap;

    i32 new_cap = m.cap * 2;
    if new_cap < 16 { new_cap = 16; }
    m.slots = alloc<StrSlot<V>>(new_cap);
    memset(cast(u8*, m.slots), 0, new_cap * sizeof(StrSlot<V>));
    m.cap = new_cap;
    m.count = 0;
    m.filled = 0;

    for i32 i = 0; i < old_cap; i++ {
        StrSlot<V>* sl = old + i;
        if sl.state == SLOT_USED {
            strmap_insert(m, sl.key, sl.hash, sl.val);
        }
    }
    if old != null { free(old); }
}

void strmap_set<V>(StrMap<V>* m, str key, V val) {
    if (m.filled + 1) * 4 > m.cap * 3 { strmap_grow(m); }
    strmap_insert(m, key, map_hash_str(key), val);
}

V* strmap_get<V>(StrMap<V>* m, str key) {
    if m.count == 0 { return null; }
    u32 h = map_hash_str(key);
    i32 mask = m.cap - 1;
    i32 i = cast(i32, h) & mask;
    while true {
        StrSlot<V>* sl = m.slots + i;
        if sl.state == SLOT_EMPTY { return null; }
        if sl.state == SLOT_USED && sl.hash == h && str_equal(sl.key, key) {
            return &sl.val;
        }
        i = (i + 1) & mask;
    }
    return null;
}

bool strmap_remove<V>(StrMap<V>* m, str key) {
    if m.count == 0 { return false; }
    u32 h = map_hash_str(key);
    i32 mask = m.cap - 1;
    i32 i = cast(i32, h) & mask;
    while true {
        StrSlot<V>* sl = m.slots + i;
        if sl.state == SLOT_EMPTY { return false; }
        if sl.state == SLOT_USED && sl.hash == h && str_equal(sl.key, key) {
            sl.state = SLOT_TOMB;
            m.count--;
            return true;
        }
        i = (i + 1) & mask;
    }
    return false;
}

// --- IntMap<V> (u32 keys) ------------------------------------------

struct IntSlot<V> {
    u32 key;
    i32 state;
    V val;
}

struct IntMap<V> {
    IntSlot<V>* slots;
    i32 cap;
    i32 count;
    i32 filled;
}

void intmap_init<V>(IntMap<V>* m) {
    m.slots = null;
    m.cap = 0;
    m.count = 0;
    m.filled = 0;
}

void intmap_free<V>(IntMap<V>* m) {
    if m.slots != null { free(m.slots); }
    intmap_init(m);
}

private void intmap_insert<V>(IntMap<V>* m, u32 key, V val) {
    i32 mask = m.cap - 1;
    i32 i = cast(i32, map_hash_u32(key)) & mask;
    i32 first_tomb = -1;
    while true {
        IntSlot<V>* sl = m.slots + i;
        if sl.state == SLOT_EMPTY {
            IntSlot<V>* dst = sl;
            if first_tomb >= 0 { dst = m.slots + first_tomb; }
            if dst.state == SLOT_EMPTY { m.filled++; }
            dst.key = key;
            dst.val = val;
            dst.state = SLOT_USED;
            m.count++;
            return;
        }
        if sl.state == SLOT_USED && sl.key == key {
            sl.val = val;
            return;
        }
        if sl.state == SLOT_TOMB && first_tomb < 0 { first_tomb = i; }
        i = (i + 1) & mask;
    }
}

private void intmap_grow<V>(IntMap<V>* m) {
    IntSlot<V>* old = m.slots;
    i32 old_cap = m.cap;

    i32 new_cap = m.cap * 2;
    if new_cap < 16 { new_cap = 16; }
    m.slots = alloc<IntSlot<V>>(new_cap);
    memset(cast(u8*, m.slots), 0, new_cap * sizeof(IntSlot<V>));
    m.cap = new_cap;
    m.count = 0;
    m.filled = 0;

    for i32 i = 0; i < old_cap; i++ {
        IntSlot<V>* sl = old + i;
        if sl.state == SLOT_USED {
            intmap_insert(m, sl.key, sl.val);
        }
    }
    if old != null { free(old); }
}

void intmap_set<V>(IntMap<V>* m, u32 key, V val) {
    if (m.filled + 1) * 4 > m.cap * 3 { intmap_grow(m); }
    intmap_insert(m, key, val);
}

V* intmap_get<V>(IntMap<V>* m, u32 key) {
    if m.count == 0 { return null; }
    i32 mask = m.cap - 1;
    i32 i = cast(i32, map_hash_u32(key)) & mask;
    while true {
        IntSlot<V>* sl = m.slots + i;
        if sl.state == SLOT_EMPTY { return null; }
        if sl.state == SLOT_USED && sl.key == key {
            return &sl.val;
        }
        i = (i + 1) & mask;
    }
    return null;
}

bool intmap_remove<V>(IntMap<V>* m, u32 key) {
    if m.count == 0 { return false; }
    i32 mask = m.cap - 1;
    i32 i = cast(i32, map_hash_u32(key)) & mask;
    while true {
        IntSlot<V>* sl = m.slots + i;
        if sl.state == SLOT_EMPTY { return false; }
        if sl.state == SLOT_USED && sl.key == key {
            sl.state = SLOT_TOMB;
            m.count--;
            return true;
        }
        i = (i + 1) & mask;
    }
    return false;
}

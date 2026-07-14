// map.mc — open-addressing hash maps: str keys and u32 keys.
//
// Linear probing, power-of-two capacity, tombstones, grow at 75%
// fill. Storage is parallel arrays: generic pointer fields must use
// the type parameter directly (a Slot<V>* field does not unify
// inside generic functions). Keys are borrowed and must outlive
// their entry. Pointers from *_get are invalidated by the next
// insert.

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

struct StrMap<V> {
    str* keys;
    u32* hashes;
    i32* states;
    V* vals;
    i32 cap;
    i32 count;
    i32 filled;   // used + tombstones
}

void strmap_init<V>(StrMap<V>* m) {
    m.keys = null;
    m.hashes = null;
    m.states = null;
    m.vals = null;
    m.cap = 0;
    m.count = 0;
    m.filled = 0;
}

void strmap_free<V>(StrMap<V>* m) {
    if m.keys != null {
        free(m.keys);
        free(m.hashes);
        free(m.states);
        free(m.vals);
    }
    strmap_init<V>(m);
}

private void strmap_insert<V>(StrMap<V>* m, str key, u32 h, V val) {
    i32 mask = m.cap - 1;
    i32 i = cast(i32, h) & mask;
    i32 first_tomb = -1;
    while true {
        i32 st = *(m.states + i);
        if st == SLOT_EMPTY {
            i32 at = i;
            if first_tomb >= 0 { at = first_tomb; }
            if *(m.states + at) == SLOT_EMPTY { m.filled++; }
            *(m.keys + at) = key;
            *(m.hashes + at) = h;
            *(m.vals + at) = val;
            *(m.states + at) = SLOT_USED;
            m.count++;
            return;
        }
        if st == SLOT_USED && *(m.hashes + i) == h && str_equal(*(m.keys + i), key) {
            *(m.vals + i) = val;
            return;
        }
        if st == SLOT_TOMB && first_tomb < 0 { first_tomb = i; }
        i = (i + 1) & mask;
    }
}

private void strmap_grow<V>(StrMap<V>* m) {
    var old_keys = m.keys;
    var old_hashes = m.hashes;
    var old_states = m.states;
    var old_vals = m.vals;
    i32 old_cap = m.cap;

    i32 new_cap = m.cap * 2;
    if new_cap < 16 { new_cap = 16; }
    m.keys = alloc<str>(new_cap);
    m.hashes = alloc<u32>(new_cap);
    m.states = alloc<i32>(new_cap);
    m.vals = alloc<V>(new_cap);
    memset(cast(u8*, m.states), 0, new_cap * sizeof(i32));
    m.cap = new_cap;
    m.count = 0;
    m.filled = 0;

    for i32 i = 0; i < old_cap; i++ {
        if *(old_states + i) == SLOT_USED {
            strmap_insert<V>(m, *(old_keys + i), *(old_hashes + i), *(old_vals + i));
        }
    }
    if old_keys != null {
        free(old_keys);
        free(old_hashes);
        free(old_states);
        free(old_vals);
    }
}

void strmap_set<V>(StrMap<V>* m, str key, V val) {
    if (m.filled + 1) * 4 > m.cap * 3 { strmap_grow<V>(m); }
    strmap_insert<V>(m, key, map_hash_str(key), val);
}

V* strmap_get<V>(StrMap<V>* m, str key) {
    if m.count == 0 { return null; }
    u32 h = map_hash_str(key);
    i32 mask = m.cap - 1;
    i32 i = cast(i32, h) & mask;
    while true {
        i32 st = *(m.states + i);
        if st == SLOT_EMPTY { return null; }
        if st == SLOT_USED && *(m.hashes + i) == h && str_equal(*(m.keys + i), key) {
            return m.vals + i;
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
        i32 st = *(m.states + i);
        if st == SLOT_EMPTY { return false; }
        if st == SLOT_USED && *(m.hashes + i) == h && str_equal(*(m.keys + i), key) {
            *(m.states + i) = SLOT_TOMB;
            m.count--;
            return true;
        }
        i = (i + 1) & mask;
    }
    return false;
}

// --- IntMap<V> (u32 keys) ------------------------------------------

struct IntMap<V> {
    u32* keys;
    i32* states;
    V* vals;
    i32 cap;
    i32 count;
    i32 filled;
}

void intmap_init<V>(IntMap<V>* m) {
    m.keys = null;
    m.states = null;
    m.vals = null;
    m.cap = 0;
    m.count = 0;
    m.filled = 0;
}

void intmap_free<V>(IntMap<V>* m) {
    if m.keys != null {
        free(m.keys);
        free(m.states);
        free(m.vals);
    }
    intmap_init<V>(m);
}

private void intmap_insert<V>(IntMap<V>* m, u32 key, V val) {
    i32 mask = m.cap - 1;
    i32 i = cast(i32, map_hash_u32(key)) & mask;
    i32 first_tomb = -1;
    while true {
        i32 st = *(m.states + i);
        if st == SLOT_EMPTY {
            i32 at = i;
            if first_tomb >= 0 { at = first_tomb; }
            if *(m.states + at) == SLOT_EMPTY { m.filled++; }
            *(m.keys + at) = key;
            *(m.vals + at) = val;
            *(m.states + at) = SLOT_USED;
            m.count++;
            return;
        }
        if st == SLOT_USED && *(m.keys + i) == key {
            *(m.vals + i) = val;
            return;
        }
        if st == SLOT_TOMB && first_tomb < 0 { first_tomb = i; }
        i = (i + 1) & mask;
    }
}

private void intmap_grow<V>(IntMap<V>* m) {
    var old_keys = m.keys;
    var old_states = m.states;
    var old_vals = m.vals;
    i32 old_cap = m.cap;

    i32 new_cap = m.cap * 2;
    if new_cap < 16 { new_cap = 16; }
    m.keys = alloc<u32>(new_cap);
    m.states = alloc<i32>(new_cap);
    m.vals = alloc<V>(new_cap);
    memset(cast(u8*, m.states), 0, new_cap * sizeof(i32));
    m.cap = new_cap;
    m.count = 0;
    m.filled = 0;

    for i32 i = 0; i < old_cap; i++ {
        if *(old_states + i) == SLOT_USED {
            intmap_insert<V>(m, *(old_keys + i), *(old_vals + i));
        }
    }
    if old_keys != null {
        free(old_keys);
        free(old_states);
        free(old_vals);
    }
}

void intmap_set<V>(IntMap<V>* m, u32 key, V val) {
    if (m.filled + 1) * 4 > m.cap * 3 { intmap_grow<V>(m); }
    intmap_insert<V>(m, key, val);
}

V* intmap_get<V>(IntMap<V>* m, u32 key) {
    if m.count == 0 { return null; }
    i32 mask = m.cap - 1;
    i32 i = cast(i32, map_hash_u32(key)) & mask;
    while true {
        i32 st = *(m.states + i);
        if st == SLOT_EMPTY { return null; }
        if st == SLOT_USED && *(m.keys + i) == key {
            return m.vals + i;
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
        i32 st = *(m.states + i);
        if st == SLOT_EMPTY { return false; }
        if st == SLOT_USED && *(m.keys + i) == key {
            *(m.states + i) = SLOT_TOMB;
            m.count--;
            return true;
        }
        i = (i + 1) & mask;
    }
    return false;
}

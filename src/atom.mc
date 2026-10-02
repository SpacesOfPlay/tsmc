// atom.mc — interned strings. An Atom is a u32 index; equal names always
// intern to the same atom.
//
// An atom interned with atom_intern is pinned: the compiler, the
// builtins and the modules keep its id wherever they like. An atom that
// atom_intern_dyn creates, for a property name that arrives as data (a
// computed key, a JSON key, a header name), is not, and atoms_sweep frees
// it once no live property uses it as a key and the program has allocated
// a grace period's worth since it was last interned. Its id is then
// reused. atom_intern on a dynamic atom's name pins it.

import vec;
import str;
import map;

type Atom = u32;

// An atom's stamp: pinned, free, or the allocation clock when a dynamic
// atom was last interned.
const i64 ATOM_PINNED = -1;
const i64 ATOM_FREE = -2;

// How much the program allocates before an unused dynamic atom may go:
// code that holds an id it has not stored yet does not allocate this much
// in between, and the atoms kept unused are bounded by it.
const i64 ATOM_GRACE_BYTES = 1048576;

struct AtomTable {
    StrMap<u32> map;     // name → atom
    Vec<str> names;      // atom → name (table-owned bytes; empty when free)
    Vec<i64> stamp;      // atom → ATOM_PINNED, ATOM_FREE or a clock
    Vec<u32> free_ids;   // freed atoms, reused first
    i32 n_dynamic;       // dynamic atoms in use
}

void atoms_init(AtomTable* t) {
    strmap_init<u32>(&t.map);
    vec_init<str>(&t.names, 64);
    vec_init<i64>(&t.stamp, 64);
    vec_init<u32>(&t.free_ids, 16);
    t.n_dynamic = 0;
}

void atoms_free(AtomTable* t) {
    for i32 i = 0; i < t.names.len; i++ {
        str s = vec_get(&t.names, i);
        if s.data != null { free(s.data); }
    }
    vec_free(&t.names);
    vec_free(&t.stamp);
    vec_free(&t.free_ids);
    strmap_free<u32>(&t.map);
}

private Atom atom_add(AtomTable* t, str name, i64 stamp) {
    u8* data = alloc<u8>(name.len + 1);
    if name.len > 0 { memcpy(data, name.data, name.len); }
    str owned;
    owned.data = data;
    owned.len = name.len;
    u32 id;
    if t.free_ids.len > 0 {
        id = vec_pop(&t.free_ids);
        vec_set(&t.names, cast(i32, id), owned);
        vec_set(&t.stamp, cast(i32, id), stamp);
    } else {
        id = t.names.len;
        vec_push(&t.names, owned);
        vec_push(&t.stamp, stamp);
    }
    strmap_set<u32>(&t.map, owned, id);
    return id;
}

Atom atom_intern(AtomTable* t, str name) {
    u32* found = strmap_get<u32>(&t.map, name);
    if found != null {
        i32 i = cast(i32, *found);
        if vec_get(&t.stamp, i) != ATOM_PINNED {
            vec_set(&t.stamp, i, ATOM_PINNED);
            t.n_dynamic--;
        }
        return *found;
    }
    return atom_add(t, name, ATOM_PINNED);
}

// The atom for a name that arrives as data; `now` is the allocation clock.
Atom atom_intern_dyn(AtomTable* t, str name, i64 now) {
    u32* found = strmap_get<u32>(&t.map, name);
    if found != null {
        i32 i = cast(i32, *found);
        if vec_get(&t.stamp, i) != ATOM_PINNED { vec_set(&t.stamp, i, now); }
        return *found;
    }
    t.n_dynamic++;
    return atom_add(t, name, now);
}

str atom_name(AtomTable* t, Atom a) {
    return vec_get(&t.names, cast(i32, a));
}

i32 atom_count(AtomTable* t) {
    return t.names.len;
}

// Frees each dynamic atom that `marks` (a byte per atom, from the
// collector) does not show in use and that was last interned at least
// ATOM_GRACE_BYTES before `now`. Returns how many went.
i32 atoms_sweep(AtomTable* t, u8* marks, i32 n, i64 now) {
    i32 freed = 0;
    if t.n_dynamic == 0 { return 0; }
    for i32 i = 0; i < n && i < t.names.len; i++ {
        i64 st = vec_get(&t.stamp, i);
        if st < 0 || *(marks + i) != cast(u8, 0) || now - st < ATOM_GRACE_BYTES { continue; }
        str s = vec_get(&t.names, i);
        ignore strmap_remove<u32>(&t.map, s);
        free(s.data);
        str empty;
        empty.data = null;
        empty.len = 0;
        vec_set(&t.names, i, empty);
        vec_set(&t.stamp, i, ATOM_FREE);
        vec_push(&t.free_ids, cast(u32, i));
        t.n_dynamic--;
        freed++;
    }
    return freed;
}

// atom.mc — interned strings. An Atom is a stable u32 index; equal
// names always intern to the same atom.

import vec;
import str;
import map;

type Atom = u32;

struct AtomTable {
    StrMap<u32> map;     // name → atom
    Vec<str> names;      // atom → name (table-owned bytes)
}

void atoms_init(AtomTable* t) {
    strmap_init<u32>(&t.map);
    vec_init<str>(&t.names, 64);
}

void atoms_free(AtomTable* t) {
    for i32 i = 0; i < t.names.len; i++ {
        str s = vec_get(&t.names, i);
        free(s.data);
    }
    vec_free(&t.names);
    strmap_free<u32>(&t.map);
}

Atom atom_intern(AtomTable* t, str name) {
    u32* found = strmap_get<u32>(&t.map, name);
    if found != null { return *found; }

    u8* data = alloc<u8>(name.len + 1);
    if name.len > 0 { memcpy(data, name.data, name.len); }
    str owned;
    owned.data = data;
    owned.len = name.len;

    u32 id = t.names.len;
    vec_push(&t.names, owned);
    strmap_set<u32>(&t.map, owned, id);
    return id;
}

str atom_name(AtomTable* t, Atom a) {
    return vec_get(&t.names, cast(i32, a));
}

i32 atom_count(AtomTable* t) {
    return t.names.len;
}

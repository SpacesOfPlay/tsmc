// test_atom.mc — atom interning: stable ids, name round trips.

import str;
import "../helpers/check.mc";
import "../../src/atom.mc";

i32 main() {
    AtomTable t;
    atoms_init(&t);

    Atom a = atom_intern(&t, "foo");
    Atom b = atom_intern(&t, "bar");
    Atom a2 = atom_intern(&t, "foo");
    check(a == a2, "same name same atom");
    check(a != b, "different name different atom");
    check_eq(atom_count(&t), 2, "count");
    check(str_equal(atom_name(&t, a), "foo"), "name round trip");
    check(str_equal(atom_name(&t, b), "bar"), "name round trip 2");

    // interned copy is independent of the caller's buffer
    u8* buf = alloc<u8>(3);
    *(buf + 0) = 'x';
    *(buf + 1) = 'y';
    *(buf + 2) = 'z';
    str temp;
    temp.data = buf;
    temp.len = 3;
    Atom x = atom_intern(&t, temp);
    *(buf + 0) = '?';
    free(buf);
    check(str_equal(atom_name(&t, x), "xyz"), "table owns its bytes");
    check(atom_intern(&t, "xyz") == x, "re-intern after source freed");

    // many atoms: ids are dense and stable
    bool ok = true;
    for i32 i = 0; i < 500; i++ {
        string s = format("atom_{}", i);
        Atom got = atom_intern(&t, s);
        Atom again = atom_intern(&t, s);
        if got != again { ok = false; }
        free(s);
    }
    check(ok, "500 dynamic atoms stable");
    check_eq(atom_count(&t), 503, "final count");

    atoms_free(&t);
    return check_done("test_atom");
}

// test_atom.mc — atom interning: stable ids, name round trips, and the
// reclaiming of dynamic atoms.

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

    // dynamic atoms: freed when unmarked past the grace period, ids reused,
    // pinned ones kept
    AtomTable d;
    atoms_init(&d);
    Atom pin = atom_intern(&d, "pinned");
    Atom used = atom_intern_dyn(&d, "used", 0);
    Atom gone = atom_intern_dyn(&d, "gone", 0);
    Atom young = atom_intern_dyn(&d, "young", ATOM_GRACE_BYTES);
    Atom later = atom_intern_dyn(&d, "later", 0);
    check(atom_intern(&d, "later") == later, "a dynamic name interned again is the same atom");
    check_eq(d.n_dynamic, 3, "three dynamic atoms, one pinned since");
    u8[8] marks;
    for i32 i = 0; i < 8; i++ { marks[i] = 0; }
    marks[used] = 1;
    i64 now = ATOM_GRACE_BYTES + 10;
    check_eq(atoms_sweep(&d, &marks[0], atom_count(&d), now), 1, "one atom freed");
    check(str_equal(atom_name(&d, used), "used"), "a marked atom stays");
    check(str_equal(atom_name(&d, young), "young"), "an atom inside its grace period stays");
    check(str_equal(atom_name(&d, pin), "pinned"), "a pinned atom stays");
    check(str_equal(atom_name(&d, later), "later"), "a re-pinned atom stays");
    check_eq(atom_name(&d, gone).len, 0, "a freed atom reads as an empty name");
    Atom fresh = atom_intern_dyn(&d, "fresh", now);
    check(str_equal(atom_name(&d, fresh), "fresh"), "a new atom has its name");
    check_eq(atom_count(&d), 5, "freed ids are reused before the table grows");
    Atom g2 = atom_intern_dyn(&d, "gone", now);
    check(str_equal(atom_name(&d, g2), "gone"), "a freed name interns anew");
    check(atom_intern_dyn(&d, "gone", now) == g2, "and is found again");

    // many short-lived names: the table stays at what is in use
    for i32 round = 0; round < 50; round++ {
        for i32 i = 0; i < 1000; i++ {
            string s = format("k{}_{}", round, i);
            ignore atom_intern_dyn(&d, s, now);
            free(s);
        }
        now = now + ATOM_GRACE_BYTES;
        u8* m = alloc<u8>(atom_count(&d));
        for i32 i = 0; i < atom_count(&d); i++ { *(m + i) = 0; }
        ignore atoms_sweep(&d, m, atom_count(&d), now);
        free(m);
    }
    check(atom_count(&d) < 1100, "50,000 short-lived names reuse about a thousand ids");
    check(str_equal(atom_name(&d, pin), "pinned"), "the pinned atom survives the churn");
    atoms_free(&d);
    return check_done("test_atom");
}

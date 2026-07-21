// test_ca_roots.mc — trusted root store: the generated Mozilla bundle parses,
// looks up by subject DN, and (as a real-world crypto check) every root with
// a supported algorithm self-verifies: RSA and ECDSA over P-256 and P-384.
// The only expected failure is the single P-521-keyed root (unsupported
// curve, fails closed); RSA-SHA1 roots are skipped (SHA-1 refused; a trust
// anchor's own self-signature is never required anyway). Exit 0 = pass.
// Compiles the vendored picotls crypto (heavy build).

import "../helpers/check.mc";
import "../../src/tls_x509.mc";
import "../../src/tls_verify.mc";
import "../../src/ca_roots.mc";

i32 main() {
    check_eq(ca_root_count(), 119, "root count (pins the current bundle)");

    // Every real Mozilla root parses; every supported-algorithm root
    // self-verifies (validates the parser and all signature paths at scale).
    i32 parsed = 0;
    i32 sha1 = 0;
    i32 self_ok = 0;
    i32 self_fail = 0;
    for i32 i = 0; i < ca_root_count(); i++ {
        u8* der;
        u64 dl;
        check(ca_root_get(i, &der, &dl), "ca_root_get in range");
        X509Cert r;
        if !x509_parse(der, dl, &r) { continue; }
        parsed++;
        u16 a = r.sig_alg_id;
        if a == X509_SIG_RSA_SHA1 { sha1++; continue; }
        if x509_verify_signature(&r, &r) { self_ok++; } else { self_fail++; }
    }
    check_eq(parsed, ca_root_count(), "every root parses");
    check_eq(sha1, 4, "SHA-1 self-signed roots (skipped)");
    check_eq(self_ok, 114, "all RSA + P-256 + P-384 roots self-verify");
    check_eq(self_fail, 1, "only the P-521 root fails closed");

    // Lookup: a root is found by its own subject DN, and the hit matches.
    u8* d0;
    u64 l0;
    check(ca_root_get(0, &d0, &l0), "get root 0");
    X509Cert r0;
    check(x509_parse(d0, l0, &r0), "parse root 0");
    i32 found = ca_root_find_by_subject(r0.buf + r0.subject.off, r0.subject.len, 0);
    check(found >= 0, "root 0 discoverable by its subject DN");
    u8* df;
    u64 lf;
    check(ca_root_get(found, &df, &lf), "get the found root");
    X509Cert rf;
    check(x509_parse(df, lf, &rf), "parse the found root");
    check(x509_range_equal(&rf, rf.subject, &r0, r0.subject), "found subject equals the query");

    // Every root is discoverable by its own subject DN.
    i32 all_found = 0;
    for i32 i = 0; i < ca_root_count(); i++ {
        u8* der;
        u64 dl;
        ca_root_get(i, &der, &dl);
        X509Cert r;
        if !x509_parse(der, dl, &r) { continue; }
        if ca_root_find_by_subject(r.buf + r.subject.off, r.subject.len, 0) >= 0 { all_found++; }
    }
    check_eq(all_found, ca_root_count(), "every root found by its subject DN");

    // A DN not in the store is not found.
    u8[7] bogus = { 0x30, 0x05, 0x02, 0x03, 0x01, 0x02, 0x03 };
    check_eq(ca_root_find_by_subject(&bogus[0], cast(u64, 7), 0), 0 - 1, "unknown DN not found");

    return check_done("ca_roots");
}

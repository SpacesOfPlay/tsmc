// test_ca_roots.mc — trusted root store: the generated Mozilla bundle parses,
// looks up by subject DN, and (as a real-world crypto check) every RSA root
// and every ECDSA-P256 root self-verifies with the I2 signature code.
// Exit 0 = pass. Compiles the vendored picotls crypto (heavy build).
//
// P-384/P-521 roots are present for DN lookup but their signatures are not
// verifiable (uECC here is P-256 only); such chains fail closed. See
// src/ca_roots.mc.

import "../helpers/check.mc";
import "../../src/tls_x509.mc";
import "../../src/tls_verify.mc";
import "../../src/ca_roots.mc";

i32 main() {
    check_eq(ca_root_count(), 119, "root count (pins the current bundle)");

    // Every real Mozilla root parses; every RSA and ECDSA-P256 root
    // self-verifies (validates the I1 parser and I2 crypto at scale).
    i32 parsed = 0;
    i32 rsa_self = 0;
    i32 rsa_fail = 0;
    i32 ec256_self = 0;
    for i32 i = 0; i < ca_root_count(); i++ {
        u8* der;
        u64 dl;
        check(ca_root_get(i, &der, &dl), "ca_root_get in range");
        X509Cert r;
        if !x509_parse(der, dl, &r) { continue; }
        parsed++;
        u16 a = r.sig_alg_id;
        if a == X509_SIG_RSA_SHA256 || a == X509_SIG_RSA_SHA384 || a == X509_SIG_RSA_SHA512 {
            if x509_verify_signature(&r, &r) { rsa_self++; } else { rsa_fail++; }
        } else if a == X509_SIG_ECDSA_SHA256 {
            if x509_verify_signature(&r, &r) { ec256_self++; }   // true only for P-256 keys
        }
    }
    check_eq(parsed, ca_root_count(), "every root parses");
    check_eq(rsa_fail, 0, "no RSA root fails self-verification");
    check(rsa_self >= 50, "the RSA roots self-verify at scale");
    check(ec256_self >= 1, "a real ECDSA-P256 root self-verifies");

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

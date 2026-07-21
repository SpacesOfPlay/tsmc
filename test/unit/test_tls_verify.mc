// test_tls_verify.mc — certificate signature verification over the embedded
// controlled chains: root (RSA, self-signed) -> intermediate (ECDSA key,
// RSA-signed) -> leaf_ec / leaf_rsa (ECDSA-signed), plus the P-384 set
// (P-384 root signing P-384/P-256 children with SHA-384/SHA-512, and a
// P-256 CA signing with SHA-384). Exercises RSA PKCS#1 v1.5, ECDSA-P256,
// ECDSA-P384, digest truncation, and tamper negatives. Exit 0 = pass.
// Compiles the vendored picotls crypto (heavy build).

import "../helpers/check.mc";
import "../helpers/x509_fixtures.mc";
import "../helpers/x509_fixtures_p384.mc";
import "../../src/tls_x509.mc";
import "../../src/tls_p384.mc";
import "../../src/tls_verify.mc";

i32 main() {
    X509Cert root;
    X509Cert inter;
    X509Cert leaf_ec;
    X509Cert leaf_rsa;
    check(x509_parse(&X509_ROOT[0], cast(u64, X509_ROOT_LEN), &root), "parse root");
    check(x509_parse(&X509_INTER[0], cast(u64, X509_INTER_LEN), &inter), "parse inter");
    check(x509_parse(&X509_LEAF_EC[0], cast(u64, X509_LEAF_EC_LEN), &leaf_ec), "parse leaf_ec");
    check(x509_parse(&X509_LEAF_RSA[0], cast(u64, X509_LEAF_RSA_LEN), &leaf_rsa), "parse leaf_rsa");

    // --- positives: each cert verifies under its true issuer ---
    check(x509_verify_signature(&root, &root), "root self-signature (RSA-PKCS1v1.5)");
    check(x509_verify_signature(&inter, &root), "inter signed by root (RSA-PKCS1v1.5)");
    check(x509_verify_signature(&leaf_ec, &inter), "leaf_ec signed by inter (ECDSA)");
    check(x509_verify_signature(&leaf_rsa, &inter), "leaf_rsa signed by inter (ECDSA)");

    // --- negatives: wrong issuer key must not verify ---
    check(!x509_verify_signature(&inter, &leaf_ec), "inter not verifiable under leaf_ec");
    check(!x509_verify_signature(&leaf_ec, &root), "leaf_ec not verifiable under root");
    check(!x509_verify_signature(&leaf_ec, &leaf_rsa), "leaf_ec not verifiable under leaf_rsa");
    check(!x509_verify_signature(&leaf_rsa, &root), "leaf_rsa not verifiable under root");
    check(!x509_verify_signature(&root, &inter), "root not verifiable under inter");

    // --- tamper: a flipped tbsCertificate byte breaks the signature ---
    // (either the cert fails to parse or the signature fails — both reject)
    u8[657] tb;
    for i32 i = 0; i < 657; i++ { tb[i] = X509_INTER[i]; }
    tb[120] = cast(u8, cast(i32, tb[120]) ^ 0xff);   // a byte inside the TBS
    X509Cert ti;
    bool tp = x509_parse(&tb[0], cast(u64, 657), &ti);
    check(!tp || !x509_verify_signature(&ti, &root), "tampered inter TBS rejected");

    // --- tamper: a flipped RSA signature byte fails to verify ---
    u8[657] sb;
    for i32 i = 0; i < 657; i++ { sb[i] = X509_INTER[i]; }
    sb[655] = cast(u8, cast(i32, sb[655]) ^ 0xff);   // a byte inside the signature
    X509Cert si;
    bool sp = x509_parse(&sb[0], cast(u64, 657), &si);
    check(!sp || !x509_verify_signature(&si, &root), "tampered inter signature rejected");

    // --- tamper: a flipped leaf_ec TBS byte breaks the ECDSA signature ---
    u8[498] eb;
    for i32 i = 0; i < 498; i++ { eb[i] = X509_LEAF_EC[i]; }
    eb[200] = cast(u8, cast(i32, eb[200]) ^ 0xff);
    X509Cert ei;
    bool ep = x509_parse(&eb[0], cast(u64, 498), &ei);
    check(!ep || !x509_verify_signature(&ei, &inter), "tampered leaf_ec TBS rejected");

    // --- P-384 set ---
    X509Cert p384_root;
    X509Cert p384_leaf;
    X509Cert p384_mixed;
    X509Cert p384_s512;
    X509Cert p256_ca;
    X509Cert p256_s384;
    check(x509_parse(&X509_P384_ROOT[0], cast(u64, X509_P384_ROOT_LEN), &p384_root), "parse p384_root");
    check(x509_parse(&X509_P384_LEAF[0], cast(u64, X509_P384_LEAF_LEN), &p384_leaf), "parse p384_leaf");
    check(x509_parse(&X509_P384_MIXED[0], cast(u64, X509_P384_MIXED_LEN), &p384_mixed), "parse p384_mixed");
    check(x509_parse(&X509_P384_S512_LEAF[0], cast(u64, X509_P384_S512_LEAF_LEN), &p384_s512), "parse p384_s512");
    check(x509_parse(&X509_P256_CA[0], cast(u64, X509_P256_CA_LEN), &p256_ca), "parse p256_ca");
    check(x509_parse(&X509_P256_S384_LEAF[0], cast(u64, X509_P256_S384_LEAF_LEN), &p256_s384), "parse p256_s384");

    check_eq(cast(i32, p384_leaf.sig_alg_id), cast(i32, X509_SIG_ECDSA_SHA384), "p384_leaf alg is ECDSA-SHA384");
    check_eq(cast(i32, p384_s512.sig_alg_id), cast(i32, X509_SIG_ECDSA_SHA512), "p384_s512 alg is ECDSA-SHA512");

    // positives: self-signed, cross-signed, mixed curves, SHA-512 truncation
    check(x509_verify_signature(&p384_root, &p384_root), "p384_root self-signature");
    check(x509_verify_signature(&p384_leaf, &p384_root), "p384_leaf signed by p384_root");
    check(x509_verify_signature(&p384_mixed, &p384_root), "P-256-keyed leaf under P-384 CA");
    check(x509_verify_signature(&p384_s512, &p384_root), "SHA-512 sig under P-384 CA");
    check(x509_verify_signature(&p256_ca, &p256_ca), "P-256 CA SHA-384 self-signature");
    check(x509_verify_signature(&p256_s384, &p256_ca), "SHA-384 sig under P-256 CA");

    // negatives: wrong issuer keys across the curve mix
    check(!x509_verify_signature(&p384_leaf, &p256_ca), "p384_leaf not under p256_ca");
    check(!x509_verify_signature(&p256_s384, &p384_root), "p256_s384 not under p384_root");
    check(!x509_verify_signature(&p384_root, &root), "p384_root not under the RSA root");

    // tamper: flipped TBS byte and flipped signature byte (P-384 path).
    // Copy by the generated length so fixture regeneration cannot break this.
    u8[1024] pb;
    i32 plen = X509_P384_LEAF_LEN;
    for i32 i = 0; i < plen; i++ { pb[i] = X509_P384_LEAF[i]; }
    pb[150] = cast(u8, cast(i32, pb[150]) ^ 0xff);
    X509Cert pi;
    bool pp = x509_parse(&pb[0], cast(u64, plen), &pi);
    check(!pp || !x509_verify_signature(&pi, &p384_root), "tampered p384_leaf TBS rejected");
    for i32 i = 0; i < plen; i++ { pb[i] = X509_P384_LEAF[i]; }
    pb[plen - 4] = cast(u8, cast(i32, pb[plen - 4]) ^ 0xff);
    bool sp2 = x509_parse(&pb[0], cast(u64, plen), &pi);
    check(!sp2 || !x509_verify_signature(&pi, &p384_root), "tampered p384_leaf sig rejected");

    // degenerate signatures must be rejected outright
    u8[96] zero_sig;
    for i32 i = 0; i < 96; i++ { zero_sig[i] = cast(u8, 0); }
    u8[96] some_pub;
    for i32 i = 0; i < 96; i++ { some_pub[i] = cast(u8, i + 1); }
    u8[48] some_hash;
    for i32 i = 0; i < 48; i++ { some_hash[i] = cast(u8, i); }
    check(!p384_ecdsa_verify(&some_pub[0], &some_hash[0], 48, &zero_sig[0]), "r=s=0 rejected");

    return check_done("tls_verify");
}

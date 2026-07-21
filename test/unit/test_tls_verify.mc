// test_tls_verify.mc — certificate signature verification over the embedded
// controlled chain: root (RSA, self-signed) -> intermediate (ECDSA key, RSA-
// signed) -> leaf_ec / leaf_rsa (ECDSA-signed). Exercises both the RSA
// PKCS#1 v1.5 and the ECDSA-P256 verify paths, plus tamper negatives.
// Exit 0 = pass. Compiles the vendored picotls crypto (heavy build).

import "../helpers/check.mc";
import "../helpers/x509_fixtures.mc";
import "../../src/tls_x509.mc";
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

    return check_done("tls_verify");
}

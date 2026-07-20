// test_x509.mc — X.509 parser, DN comparison, and RFC 6125 hostname
// matching, against an embedded controlled chain (see gen_test_certs.sh):
//   root (RSA CA) -> intermediate (ECDSA CA) -> leaf_ec / leaf_rsa.
// Deterministic, no network. Exit 0 = pass.

import str;
import "../helpers/check.mc";
import "../helpers/x509_fixtures.mc";
import "../../src/tls_x509.mc";

// Validity as unix seconds (openssl -startdate/-enddate of the fixtures).
const i64 LEAF_NOT_BEFORE = 1784580560;   // Jul 20 20:49:20 2026 GMT
const i64 LEAF_NOT_AFTER  = 1853700560;   // Sep 27 20:49:20 2028 GMT
const i64 ROOT_NOT_BEFORE = 1784580536;   // Jul 20 20:48:56 2026 GMT
const i64 ROOT_NOT_AFTER  = 2415300536;   // Jul 15 20:48:56 2046 GMT

// Match a host string against a leaf's SAN.
private bool host_ok(X509Cert* leaf, str h) {
    return x509_match_hostname(leaf, h.data, h.len);
}

// Run one pattern/host case through the pure dNSName matcher.
private bool dns_ok(str pat, str host) {
    return x509_dnsname_match(pat.data, pat.len, host.data, host.len);
}

i32 main() {
    X509Cert root;
    X509Cert inter;
    X509Cert leaf_ec;
    X509Cert leaf_rsa;

    check(x509_parse(&X509_ROOT[0], cast(u64, X509_ROOT_LEN), &root), "parse root");
    check(x509_parse(&X509_INTER[0], cast(u64, X509_INTER_LEN), &inter), "parse inter");
    check(x509_parse(&X509_LEAF_EC[0], cast(u64, X509_LEAF_EC_LEN), &leaf_ec), "parse leaf_ec");
    check(x509_parse(&X509_LEAF_RSA[0], cast(u64, X509_LEAF_RSA_LEN), &leaf_rsa), "parse leaf_rsa");

    // --- basicConstraints ---
    check(root.has_basic_constraints && root.is_ca, "root is CA");
    check(inter.has_basic_constraints && inter.is_ca, "inter is CA");
    check_eq(inter.path_len, 0, "inter pathlen 0");
    check(leaf_ec.has_basic_constraints && !leaf_ec.is_ca, "leaf_ec not CA");
    check(!leaf_rsa.is_ca, "leaf_rsa not CA");

    // --- keyUsage ---
    check((leaf_ec.key_usage & X509_KU_DIGITAL_SIGNATURE) != 0, "leaf_ec digitalSignature");
    check((inter.key_usage & X509_KU_KEY_CERT_SIGN) != 0, "inter keyCertSign");
    check((leaf_ec.key_usage & X509_KU_KEY_CERT_SIGN) == 0, "leaf_ec not keyCertSign");

    // --- validity ---
    check_eq_i64(leaf_ec.not_before, LEAF_NOT_BEFORE, "leaf notBefore");
    check_eq_i64(leaf_ec.not_after, LEAF_NOT_AFTER, "leaf notAfter");
    check_eq_i64(root.not_before, ROOT_NOT_BEFORE, "root notBefore");
    check_eq_i64(root.not_after, ROOT_NOT_AFTER, "root notAfter");

    // --- signatureAlgorithm: inner/outer agree, no SHA-1, expected algs ---
    check(root.sig_alg_id == root.tbs_sig_alg_id, "root sig alg inner==outer");
    check(inter.sig_alg_id == inter.tbs_sig_alg_id, "inter sig alg inner==outer");
    check(leaf_ec.sig_alg_id == leaf_ec.tbs_sig_alg_id, "leaf_ec sig alg inner==outer");
    check_eq(cast(i32, inter.sig_alg_id), cast(i32, X509_SIG_RSA_SHA256), "inter signed RSA-SHA256");
    check_eq(cast(i32, leaf_ec.sig_alg_id), cast(i32, X509_SIG_ECDSA_SHA256), "leaf_ec signed ECDSA-SHA256");

    // --- SPKI located ---
    check(leaf_ec.spki.len > cast(u64, 0) && X509_LEAF_EC[leaf_ec.spki.off] == cast(u8, 0x30), "leaf_ec SPKI is a SEQUENCE");
    check(inter.spki.len > cast(u64, 0), "inter SPKI located");

    // --- chain linkage by exact-DER DN ---
    check(x509_issuer_matches(&leaf_ec, &inter), "leaf_ec issuer == inter subject");
    check(x509_issuer_matches(&leaf_rsa, &inter), "leaf_rsa issuer == inter subject");
    check(x509_issuer_matches(&inter, &root), "inter issuer == root subject");
    check(x509_issuer_matches(&root, &root), "root self-signed (issuer == subject)");
    // negative: leaf is not issued by the root directly
    check(!x509_issuer_matches(&leaf_ec, &root), "leaf_ec issuer != root subject");

    // --- hostname matching against leaf_ec SAN {ecdsa.example.test, *.wild.example.test} ---
    check(host_ok(&leaf_ec, "ecdsa.example.test"), "exact SAN match");
    check(host_ok(&leaf_ec, "ECDSA.EXAMPLE.TEST"), "case-insensitive match");
    check(host_ok(&leaf_ec, "foo.wild.example.test"), "wildcard one-label match");
    check(!host_ok(&leaf_ec, "wild.example.test"), "wildcard needs a label");
    check(!host_ok(&leaf_ec, "a.b.wild.example.test"), "wildcard matches one label only");
    check(!host_ok(&leaf_ec, "evil.test"), "unrelated host rejected");
    check(!host_ok(&leaf_ec, "ecdsa.example.test.evil.com"), "suffix-append rejected");
    check(host_ok(&leaf_rsa, "rsa.example.test"), "leaf_rsa exact SAN match");
    check(!host_ok(&leaf_rsa, "ecdsa.example.test"), "leaf_rsa rejects other host");

    // --- pure dNSName matcher edge cases ---
    check(dns_ok("a.b.com", "a.b.com"), "plain equal");
    check(!dns_ok("a.b.com", "a.b.org"), "plain unequal");
    check(dns_ok("*.b.com", "a.b.com"), "wildcard label");
    check(!dns_ok("*.com", "a.com"), "wildcard needs >= 2 suffix labels");
    check(!dns_ok("f*o.b.com", "foo.b.com"), "partial-label wildcard rejected");
    check(!dns_ok("*a.b.com", "xa.b.com"), "non-leftmost-only wildcard rejected");
    check(!dns_ok("*.*.com", "a.b.com"), "multiple wildcards rejected");

    // embedded NUL in the pattern must never match.
    u8[7] nul_pat = { 0x61, 0x00, 0x62, 0x2e, 0x63, 0x6f, 0x6d };   // "a\0b.com"
    u8[7] nul_host = { 0x61, 0x00, 0x62, 0x2e, 0x63, 0x6f, 0x6d };
    check(!x509_dnsname_match(&nul_pat[0], 7, &nul_host[0], 7), "embedded NUL rejected");

    // --- malformation rejection ---
    X509Cert junk;
    check(!x509_parse(&X509_LEAF_EC[0], cast(u64, 100), &junk), "truncated cert rejected");
    u8[498] bad;
    for i32 i = 0; i < 498; i++ { bad[i] = X509_LEAF_EC[i]; }
    bad[0] = cast(u8, 0x31);   // corrupt outer tag (SEQUENCE -> SET)
    check(!x509_parse(&bad[0], cast(u64, 498), &junk), "bad outer tag rejected");

    return check_done("x509");
}

// test_tls_chain.mc — certificate path validation. Two fixture sets:
//
// Controlled (extra_root as the trust anchor, clock pinned mid-validity):
// the openssl chains from x509_fixtures{,_p384}.mc, exercising every
// verdict — positives incl. wildcard, then wrong host, expired, not yet
// valid, missing intermediate, untrusted root, broken linkage, bad
// signature, CA:FALSE intermediate (rogue), and a pathLenConstraint
// violation.
//
// Real (bundled Mozilla store as the anchor): a captured production chain
// (x509_fixtures_real.mc) validated exactly as the server sent it, with
// the clock pinned to the capture time. Exit 0 = pass. Heavy build.

import str;
import "../helpers/check.mc";
import "../helpers/x509_fixtures.mc";
import "../helpers/x509_fixtures_p384.mc";
import "../helpers/x509_fixtures_real.mc";
import "../../src/tls_x509.mc";
import "../../src/tls_chain.mc";

// Mid-validity clock for the controlled chains (2027-01-15).
const i64 NOW = 1800000000;

// Verify chain [c0] / [c0,c1] / [c0,c1,c2] against an optional extra root.
private i32 v1(u8* c0, i32 l0, str host, i64 now, u8* xr, i32 xl) {
    u8*[1] ders;
    u64[1] lens;
    ders[0] = c0;
    lens[0] = cast(u64, l0);
    return tls_chain_verify(&ders[0], &lens[0], 1, host.data, host.len, now, xr, cast(u64, xl));
}

private i32 v2(u8* c0, i32 l0, u8* c1, i32 l1, str host, i64 now, u8* xr, i32 xl) {
    u8*[2] ders;
    u64[2] lens;
    ders[0] = c0;
    lens[0] = cast(u64, l0);
    ders[1] = c1;
    lens[1] = cast(u64, l1);
    return tls_chain_verify(&ders[0], &lens[0], 2, host.data, host.len, now, xr, cast(u64, xl));
}

private i32 v3(u8* c0, i32 l0, u8* c1, i32 l1, u8* c2, i32 l2, str host, i64 now, u8* xr, i32 xl) {
    u8*[3] ders;
    u64[3] lens;
    ders[0] = c0;
    lens[0] = cast(u64, l0);
    ders[1] = c1;
    lens[1] = cast(u64, l1);
    ders[2] = c2;
    lens[2] = cast(u64, l2);
    return tls_chain_verify(&ders[0], &lens[0], 3, host.data, host.len, now, xr, cast(u64, xl));
}

i32 main() {
    u8* root = &X509_ROOT[0];
    i32 rootl = X509_ROOT_LEN;
    u8* inter = &X509_INTER[0];
    i32 interl = X509_INTER_LEN;
    u8* leaf = &X509_LEAF_EC[0];
    i32 leafl = X509_LEAF_EC_LEN;

    // --- controlled chain: positives ---
    check_eq(v2(leaf, leafl, inter, interl, "ecdsa.example.test", NOW, root, rootl),
             X509_V_OK, "leaf+inter anchors at the extra root");
    check_eq(v2(leaf, leafl, inter, interl, "foo.wild.example.test", NOW, root, rootl),
             X509_V_OK, "wildcard SAN accepted");
    check_eq(v3(leaf, leafl, inter, interl, root, rootl, "ecdsa.example.test", NOW, root, rootl),
             X509_V_OK, "server-appended root cert is ignored");
    check_eq(v2(&X509_LEAF_RSA[0], X509_LEAF_RSA_LEN, inter, interl, "rsa.example.test", NOW, root, rootl),
             X509_V_OK, "RSA leaf through the same chain");
    check_eq(v2(&X509_P384_LEAF[0], X509_P384_LEAF_LEN, &X509_P384_ROOT[0], X509_P384_ROOT_LEN,
                "p384.example.test", NOW, &X509_P384_ROOT[0], X509_P384_ROOT_LEN),
             X509_V_OK, "P-384 chain (root sent and also the anchor)");
    check_eq(v1(&X509_P384_LEAF[0], X509_P384_LEAF_LEN, "p384.example.test", NOW,
                &X509_P384_ROOT[0], X509_P384_ROOT_LEN),
             X509_V_OK, "leaf alone, directly signed by the anchor");

    // --- controlled chain: each failure mode ---
    check_eq(v2(leaf, leafl, inter, interl, "evil.test", NOW, root, rootl),
             X509_V_ERR_HOSTNAME, "wrong host refused");
    check_eq(v2(leaf, leafl, inter, interl, "wild.example.test", NOW, root, rootl),
             X509_V_ERR_HOSTNAME, "wildcard needs one more label");
    check_eq(v2(leaf, leafl, inter, interl, "ecdsa.example.test", 1900000000, root, rootl),
             X509_V_ERR_EXPIRED, "expired leaf refused");
    check_eq(v2(leaf, leafl, inter, interl, "ecdsa.example.test", 1700000000, root, rootl),
             X509_V_ERR_NOT_YET_VALID, "not-yet-valid leaf refused");
    check_eq(v1(leaf, leafl, "ecdsa.example.test", NOW, root, rootl),
             X509_V_ERR_UNTRUSTED, "missing intermediate refused");
    check_eq(v2(leaf, leafl, inter, interl, "ecdsa.example.test", NOW, null, 0),
             X509_V_ERR_UNTRUSTED, "no trust anchor (store miss) refused");
    check_eq(v2(leaf, leafl, root, rootl, "ecdsa.example.test", NOW, root, rootl),
             X509_V_ERR_LINK, "issuer/subject mismatch refused");

    // tampered leaf signatureValue: linkage holds, signature fails
    u8[1024] tl;
    for i32 i = 0; i < leafl; i++ { tl[i] = X509_LEAF_EC[i]; }
    tl[leafl - 4] = cast(u8, cast(i32, tl[leafl - 4]) ^ 0xff);
    i32 tampered = v2(&tl[0], leafl, inter, interl, "ecdsa.example.test", NOW, root, rootl);
    check(tampered == X509_V_ERR_SIG || tampered == X509_V_ERR_PARSE, "tampered leaf sig refused");

    // rogue CA: victim signed by a CA:FALSE end-entity must be refused
    check_eq(v2(&X509_VICTIM[0], X509_VICTIM_LEN, &X509_ROGUE[0], X509_ROGUE_LEN,
                "victim.example.test", NOW, &X509_P384_ROOT[0], X509_P384_ROOT_LEN),
             X509_V_ERR_NOT_CA, "CA:FALSE intermediate refused");

    // pathLenConstraint: mid_ca(pathlen:0) -> sub_ca -> deep_leaf
    check_eq(v3(&X509_DEEP_LEAF[0], X509_DEEP_LEAF_LEN, &X509_SUB_CA[0], X509_SUB_CA_LEN,
                &X509_MID_CA[0], X509_MID_CA_LEN, "deep.example.test", NOW,
                &X509_P384_ROOT[0], X509_P384_ROOT_LEN),
             X509_V_ERR_PATHLEN, "pathLenConstraint violation refused");
    // ...while the one-level use of the same mid_ca is fine
    check_eq(v2(&X509_SUB_CA[0], X509_SUB_CA_LEN, &X509_MID_CA[0], X509_MID_CA_LEN,
                "no.san.here", NOW, &X509_P384_ROOT[0], X509_P384_ROOT_LEN),
             X509_V_ERR_HOSTNAME, "sub_ca as leaf: fails on SAN, not pathlen");

    // evil twin: the leaf's issuer DN is byte-identical to the trusted
    // root's subject, but it was signed by a different key. An anchor
    // matched by DN alone must still be refused — the signature decides.
    X509Cert ev;
    X509Cert rt;
    check(x509_parse(&X509_EVIL_LEAF[0], cast(u64, X509_EVIL_LEAF_LEN), &ev), "parse evil_leaf");
    check(x509_parse(root, cast(u64, rootl), &rt), "parse root for DN guard");
    check(x509_range_equal(&ev, ev.issuer, &rt, rt.subject),
          "evil_leaf issuer DN collides with the root (guard)");
    check_eq(v1(&X509_EVIL_LEAF[0], X509_EVIL_LEAF_LEN, "evil-twin.example.test", NOW, root, rootl),
             X509_V_ERR_UNTRUSTED, "DN-matching anchor with the wrong key refused");

    // degenerate inputs
    u8*[1] d0;
    u64[1] ln0;
    d0[0] = leaf;
    ln0[0] = cast(u64, leafl);
    str h = "x.test";
    check_eq(tls_chain_verify(&d0[0], &ln0[0], 0, h.data, h.len, NOW, null, 0),
             X509_V_ERR_EMPTY, "empty chain refused");
    check_eq(tls_chain_verify(&d0[0], &ln0[0], 9, h.data, h.len, NOW, null, 0),
             X509_V_ERR_TOO_LONG, "overlong chain refused");
    check_eq(v2(leaf, leafl, inter, interl, "", NOW, root, rootl),
             X509_V_ERR_HOSTNAME, "empty host refused");

    // --- real production chain against the bundled Mozilla store ---
    u8*[4] rd;
    u64[4] rl;
    rd[0] = &X509_REAL_C0[0];
    rl[0] = cast(u64, X509_REAL_C0_LEN);
    rd[1] = &X509_REAL_C1[0];
    rl[1] = cast(u64, X509_REAL_C1_LEN);
    rd[2] = &X509_REAL_C2[0];
    rl[2] = cast(u64, X509_REAL_C2_LEN);
    rd[3] = &X509_REAL_C3[0];
    rl[3] = cast(u64, X509_REAL_C3_LEN);
    str rh = "example.com";
    str rw = "www.example.com";
    str rb = "evil.com";
    check_eq(tls_chain_verify(&rd[0], &rl[0], X509_REAL_COUNT, rh.data, rh.len, X509_REAL_NOW, null, 0),
             X509_V_OK, "real chain validates against the bundled store");
    check_eq(tls_chain_verify(&rd[0], &rl[0], 3, rh.data, rh.len, X509_REAL_NOW, null, 0),
             X509_V_OK, "real chain without the appended root also validates");
    check_eq(tls_chain_verify(&rd[0], &rl[0], X509_REAL_COUNT, rw.data, rw.len, X509_REAL_NOW, null, 0),
             X509_V_OK, "real wildcard SAN accepted");
    check_eq(tls_chain_verify(&rd[0], &rl[0], X509_REAL_COUNT, rb.data, rb.len, X509_REAL_NOW, null, 0),
             X509_V_ERR_HOSTNAME, "real chain, wrong host refused");
    check_eq(tls_chain_verify(&rd[0], &rl[0], 2, rh.data, rh.len, X509_REAL_NOW, null, 0),
             X509_V_ERR_UNTRUSTED, "real chain truncated mid-way refused");
    check_eq(tls_chain_verify(&rd[0], &rl[0], X509_REAL_COUNT, rh.data, rh.len,
                              X509_REAL_NOW + 315360000, null, 0),
             X509_V_ERR_EXPIRED, "real chain, clock +10y refused");
    check_eq(tls_chain_verify(&rd[0], &rl[0], X509_REAL_COUNT, rh.data, rh.len, 1000, null, 0),
             X509_V_ERR_NOT_YET_VALID, "real chain, clock in 1970 refused");

    return check_done("tls_chain");
}

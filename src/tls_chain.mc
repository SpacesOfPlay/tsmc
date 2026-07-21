// tls_chain.mc -- certificate path validation (RFC 5280 subset + RFC 6125
// hostname check). Validates a server-presented chain leaf-first against the
// bundled trust store: linkage by exact-DER DN, a verified signature at every
// step including the trust anchor (never trust on DN alone), validity
// windows, basicConstraints / pathLenConstraint / keyUsage, and the leaf SAN
// against the target host. Any failure refuses the chain with a specific
// code; there is no partial success.
//
// Scope: linear chains only. Revocation, name/policy constraints and
// cross-signing beyond a linear path are out of scope (doc/PLAN_M35).

import "tls_x509.mc";
import "tls_verify.mc";
import "ca_roots.mc";

const i32 X509_V_OK = 0;
const i32 X509_V_ERR_EMPTY = 1;           // no certificates presented
const i32 X509_V_ERR_TOO_LONG = 2;        // more than TLS_CHAIN_MAX certs
const i32 X509_V_ERR_PARSE = 3;           // malformed certificate
const i32 X509_V_ERR_HOSTNAME = 4;        // leaf SAN does not cover the host
const i32 X509_V_ERR_NOT_YET_VALID = 5;   // notBefore is in the future
const i32 X509_V_ERR_EXPIRED = 6;         // notAfter is in the past
const i32 X509_V_ERR_NOT_CA = 7;          // intermediate without cA=TRUE
const i32 X509_V_ERR_PATHLEN = 8;         // pathLenConstraint violated
const i32 X509_V_ERR_KEY_USAGE = 9;       // keyUsage forbids this role
const i32 X509_V_ERR_LINK = 10;           // issuer does not match next subject
const i32 X509_V_ERR_SIG = 11;            // signature fails under issuer key
const i32 X509_V_ERR_UNTRUSTED = 12;      // no trust anchor signs the chain

const i32 TLS_CHAIN_MAX = 8;

// Short names for error messages.
str tls_chain_err_str(i32 code) {
    if code == X509_V_OK { return "ok"; }
    if code == X509_V_ERR_EMPTY { return "empty certificate chain"; }
    if code == X509_V_ERR_TOO_LONG { return "certificate chain too long"; }
    if code == X509_V_ERR_PARSE { return "malformed certificate"; }
    if code == X509_V_ERR_HOSTNAME { return "hostname mismatch"; }
    if code == X509_V_ERR_NOT_YET_VALID { return "certificate not yet valid"; }
    if code == X509_V_ERR_EXPIRED { return "certificate expired"; }
    if code == X509_V_ERR_NOT_CA { return "intermediate is not a CA"; }
    if code == X509_V_ERR_PATHLEN { return "path length constraint violated"; }
    if code == X509_V_ERR_KEY_USAGE { return "key usage violation"; }
    if code == X509_V_ERR_LINK { return "broken issuer chain"; }
    if code == X509_V_ERR_SIG { return "certificate signature failure"; }
    if code == X509_V_ERR_UNTRUSTED { return "unable to verify to a trusted root"; }
    return "certificate verify failed";
}

private {

// Does `anchor` vouch for chain cert `c` at depth `i`? The anchor's subject
// must equal c's issuer, its key must verify c's signature, it must be
// within its own validity window, and its pathLenConstraint (if any) must
// allow the i intermediates below it. The anchor's basicConstraints and its
// own self-signature are NOT checked: a trust anchor is trusted a priori
// (several store roots are v1 certificates without extensions).
bool anchor_signs(X509Cert* c, i32 depth, i64 now, X509Cert* anchor) {
    if !x509_range_equal(anchor, anchor.subject, c, c.issuer) { return false; }
    if !x509_verify_signature(c, anchor) { return false; }
    if anchor.not_before > now || anchor.not_after < now { return false; }
    if anchor.path_len >= 0 && depth > anchor.path_len { return false; }
    return true;
}

}  // private

// Validate the presented chain (leaf first) for `host` at time `now` (unix
// seconds). extra_root, when non-null, is one additional trust anchor tried
// before the bundled store — used for tests and caller-supplied CAs. Returns
// X509_V_OK or the first failure's code.
i32 tls_chain_verify(u8** ders, u64* lens, i32 n, u8* host, i32 host_len,
                     i64 now, u8* extra_root, u64 extra_root_len) {
    if n <= 0 { return X509_V_ERR_EMPTY; }
    if n > TLS_CHAIN_MAX { return X509_V_ERR_TOO_LONG; }

    noinit X509Cert[8] chain;   // TLS_CHAIN_MAX
    for i32 i = 0; i < n; i++ {
        if !x509_parse(*(ders + i), *(lens + i), &chain[i]) { return X509_V_ERR_PARSE; }
    }
    X509Cert extra;
    bool has_extra = false;
    if extra_root != null {
        if !x509_parse(extra_root, extra_root_len, &extra) { return X509_V_ERR_PARSE; }
        has_extra = true;
    }

    // the leaf must cover the target host (SAN dNSName only, no CN fallback)
    if host_len <= 0 { return X509_V_ERR_HOSTNAME; }
    if !x509_match_hostname(&chain[0], host, host_len) { return X509_V_ERR_HOSTNAME; }
    // leaf keyUsage, when present, must allow TLS server use
    if chain[0].has_key_usage {
        u16 ok_bits = X509_KU_DIGITAL_SIGNATURE | X509_KU_KEY_ENCIPHERMENT;
        if (chain[0].key_usage & ok_bits) == 0 { return X509_V_ERR_KEY_USAGE; }
    }

    // Walk up from the leaf. At each cert, first try to anchor it in the
    // trust store; otherwise it must chain to the next presented cert. A
    // server-appended root cert is naturally ignored: its issue anchors one
    // step earlier.
    for i32 i = 0; i < n; i++ {
        X509Cert* c = &chain[i];
        if c.not_before > now { return X509_V_ERR_NOT_YET_VALID; }
        if c.not_after < now { return X509_V_ERR_EXPIRED; }
        if i > 0 {
            // this cert certified the one below it: it must be a real CA
            if !c.has_basic_constraints || !c.is_ca { return X509_V_ERR_NOT_CA; }
            if c.path_len >= 0 && i - 1 > c.path_len { return X509_V_ERR_PATHLEN; }
            if c.has_key_usage && (c.key_usage & X509_KU_KEY_CERT_SIGN) == 0 {
                return X509_V_ERR_KEY_USAGE;
            }
        }

        if has_extra && anchor_signs(c, i, now, &extra) { return X509_V_OK; }
        i32 start = 0;
        while true {
            i32 idx = ca_root_find_by_subject(c.buf + c.issuer.off, c.issuer.len, start);
            if idx < 0 { break; }
            u8* rd;
            u64 rl;
            if ca_root_get(idx, &rd, &rl) {
                X509Cert r;
                if x509_parse(rd, rl, &r) {
                    if anchor_signs(c, i, now, &r) { return X509_V_OK; }
                }
            }
            start = idx + 1;   // same-subject renewals: try the next candidate
        }

        if i + 1 >= n { return X509_V_ERR_UNTRUSTED; }
        if !x509_issuer_matches(c, &chain[i + 1]) { return X509_V_ERR_LINK; }
        if !x509_verify_signature(c, &chain[i + 1]) { return X509_V_ERR_SIG; }
    }
    return X509_V_ERR_UNTRUSTED;
}

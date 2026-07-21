// ca_roots.mc -- trusted root store lookup over the generated Mozilla CA
// bundle (tls/ca_roots_data.mc). Finding a candidate anchor by subject DN is
// only the first step: the caller must still verify that the anchor's key
// signed the chain (never trust on DN alone).
//
// The store holds every Mozilla root (for DN lookup). Signature verification
// supports RSA and ECDSA over P-256 and P-384, which covers every root in
// the current bundle except one P-521 key; a chain anchored at or passing
// through a P-521 key fails closed rather than being trusted.

import "tls_x509.mc";
import "tls/ca_roots_data.mc";

// Number of trusted roots in the store.
i32 ca_root_count() {
    return CA_ROOTS_COUNT;
}

// DER of the idx-th root (a borrow into the static blob). False if out of range.
bool ca_root_get(i32 idx, u8** der_out, u64* len_out) {
    if idx < 0 || idx >= CA_ROOTS_COUNT { return false; }
    *der_out = &CA_ROOTS_DER[CA_ROOTS_OFF[idx]];
    *len_out = cast(u64, CA_ROOTS_LEN[idx]);
    return true;
}

// Find the next trusted root at index >= start whose subject Name equals `dn`
// (a DER-encoded Name TLV) byte for byte. Returns the index, or -1 if none.
// Callers iterate (find, verify signature, advance) because several roots can
// share a subject DN across renewals/cross-signs.
i32 ca_root_find_by_subject(u8* dn, u64 dn_len, i32 start) {
    i32 i = start;
    if i < 0 { i = 0; }
    while i < CA_ROOTS_COUNT {
        u8* der;
        u64 dl;
        if ca_root_get(i, &der, &dl) {
            X509Cert r;
            if x509_parse(der, dl, &r) {
                if r.subject.len == dn_len {
                    bool eq = true;
                    for u64 j = 0; j < dn_len; j++ {
                        if r.buf[r.subject.off + j] != dn[j] { eq = false; break; }
                    }
                    if eq { return i; }
                }
            }
        }
        i = i + 1;
    }
    return 0 - 1;
}

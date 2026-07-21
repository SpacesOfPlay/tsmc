// tls_x509.mc -- defensive X.509 (RFC 5280) certificate field parser plus
// DN comparison and RFC 6125 hostname matching. Pure and allocation-free:
// it returns byte ranges into the caller's DER buffer, never copies. Every
// length and offset is bounds-checked because the input is attacker-
// controlled. This is the parsing half of CA-chain trust; signature
// verification and path building live elsewhere.

// --- signatureAlgorithm identifiers ---------------------------------------

const u16 X509_SIG_UNKNOWN = 0;
const u16 X509_SIG_RSA_SHA256 = 1;    // 1.2.840.113549.1.1.11
const u16 X509_SIG_RSA_SHA384 = 2;    // 1.2.840.113549.1.1.12
const u16 X509_SIG_RSA_SHA512 = 3;    // 1.2.840.113549.1.1.13
const u16 X509_SIG_RSA_SHA1 = 4;      // 1.2.840.113549.1.1.5  (weak)
const u16 X509_SIG_ECDSA_SHA256 = 5;  // 1.2.840.10045.4.3.2
const u16 X509_SIG_ECDSA_SHA384 = 6;  // 1.2.840.10045.4.3.3
const u16 X509_SIG_ECDSA_SHA1 = 7;    // 1.2.840.10045.4.1    (weak)
const u16 X509_SIG_ECDSA_SHA512 = 8;  // 1.2.840.10045.4.3.4

// keyUsage bits (BIT STRING, bit 0 = most significant of the first byte).
const u16 X509_KU_DIGITAL_SIGNATURE = 0x8000;   // bit 0
const u16 X509_KU_KEY_ENCIPHERMENT = 0x2000;    // bit 2
const u16 X509_KU_KEY_CERT_SIGN = 0x0400;       // bit 5

// --- parsed certificate ----------------------------------------------------

// A [off, off+len) slice into the certificate's DER buffer.
struct DerRange {
    u64 off;
    u64 len;
}

struct X509Cert {
    u8* buf;              // borrowed DER buffer (not owned)
    u64 buf_len;
    DerRange tbs;         // full TBSCertificate TLV (the signed bytes)
    DerRange sig_alg;     // outer signatureAlgorithm SEQUENCE (full TLV)
    DerRange sig_val;     // signatureValue bits (unused-bits prefix stripped)
    u16 sig_alg_id;       // outer algorithm (X509_SIG_*)
    u16 tbs_sig_alg_id;   // inner tbsCertificate.signature; must equal sig_alg_id
    DerRange issuer;      // issuer Name TLV
    DerRange subject;     // subject Name TLV
    DerRange spki;        // SubjectPublicKeyInfo TLV
    DerRange san;         // SAN GeneralNames content (len 0 if the ext is absent)
    i64 not_before;       // unix seconds
    i64 not_after;        // unix seconds
    bool has_basic_constraints;
    bool is_ca;           // basicConstraints cA
    i32 path_len;         // pathLenConstraint, -1 if absent
    bool has_key_usage;
    u16 key_usage;        // packed keyUsage bits
}

// --- DER cursor ------------------------------------------------------------

// A bounded read cursor. pos <= end is an invariant maintained throughout.
struct DerCursor {
    u8* buf;
    u64 pos;
    u64 end;
}

// One tag-length-value. The full TLV spans [hdr, content + len).
struct DerTlv {
    u8 tag;
    u64 hdr;
    u64 content;
    u64 len;
}

// --- DER cursor primitives (public: reused by signature verification) ------

// Peek the next tag byte without consuming it. Returns -1 at end.
i32 der_peek_tag(DerCursor* c) {
    if c.pos >= c.end { return 0 - 1; }
    return cast(i32, c.buf[c.pos]);
}

// Read a DER definite length, advancing the cursor. Rejects the indefinite
// form, reserved 0xFF, non-minimal encodings, and lengths that overrun the
// cursor bound. On success *out holds the content length.
bool der_read_len(DerCursor* c, u64* out) {
    if c.pos >= c.end { return false; }
    u8 b = c.buf[c.pos];
    c.pos = c.pos + 1;
    if b < cast(u8, 0x80) {
        *out = cast(u64, b);
    } else {
        i32 n = cast(i32, b & cast(u8, 0x7f));
        if n == 0 { return false; }          // indefinite form: not DER
        if n > 4 { return false; }           // certs never need > 4-byte lengths
        if c.pos >= c.end { return false; }
        if c.buf[c.pos] == cast(u8, 0) { return false; }  // leading zero: non-minimal
        u64 v = 0;
        for i32 i = 0; i < n; i++ {
            if c.pos >= c.end { return false; }
            v = (v << 8) | cast(u64, c.buf[c.pos]);
            c.pos = c.pos + 1;
        }
        if v < cast(u64, 0x80) { return false; }   // should have used short form
        *out = v;
    }
    if *out > c.end - c.pos { return false; }
    return true;
}

// Read one TLV, advancing past its content. Rejects the high-tag-number form.
bool der_read_tlv(DerCursor* c, DerTlv* out) {
    if c.pos >= c.end { return false; }
    out.hdr = c.pos;
    out.tag = c.buf[c.pos];
    c.pos = c.pos + 1;
    if (out.tag & cast(u8, 0x1f)) == cast(u8, 0x1f) { return false; }  // multi-byte tag
    u64 len;
    if !der_read_len(c, &len) { return false; }
    out.content = c.pos;
    out.len = len;
    c.pos = c.pos + len;
    return true;
}

// A cursor over the content of a constructed TLV.
DerCursor der_enter(u8* buf, DerTlv* t) {
    return DerCursor{ .buf = buf, .pos = t.content, .end = t.content + t.len };
}

// --- internal parse helpers ------------------------------------------------

private {

// --- signatureAlgorithm OID -> id ------------------------------------------

u16 x509_oid_to_sig(u8* buf, u64 off, u64 len) {
    if len == cast(u64, 9) {
        // RSA PKCS#1: 2a 86 48 86 f7 0d 01 01 XX
        if buf[off] == cast(u8, 0x2a) && buf[off+1] == cast(u8, 0x86)
           && buf[off+2] == cast(u8, 0x48) && buf[off+3] == cast(u8, 0x86)
           && buf[off+4] == cast(u8, 0xf7) && buf[off+5] == cast(u8, 0x0d)
           && buf[off+6] == cast(u8, 0x01) && buf[off+7] == cast(u8, 0x01) {
            u8 last = buf[off+8];
            if last == cast(u8, 0x0b) { return X509_SIG_RSA_SHA256; }
            if last == cast(u8, 0x0c) { return X509_SIG_RSA_SHA384; }
            if last == cast(u8, 0x0d) { return X509_SIG_RSA_SHA512; }
            if last == cast(u8, 0x05) { return X509_SIG_RSA_SHA1; }
        }
    } else if len == cast(u64, 8) {
        // ECDSA-with-SHA2: 2a 86 48 ce 3d 04 03 XX
        if buf[off] == cast(u8, 0x2a) && buf[off+1] == cast(u8, 0x86)
           && buf[off+2] == cast(u8, 0x48) && buf[off+3] == cast(u8, 0xce)
           && buf[off+4] == cast(u8, 0x3d) && buf[off+5] == cast(u8, 0x04)
           && buf[off+6] == cast(u8, 0x03) {
            u8 last = buf[off+7];
            if last == cast(u8, 0x02) { return X509_SIG_ECDSA_SHA256; }
            if last == cast(u8, 0x03) { return X509_SIG_ECDSA_SHA384; }
            if last == cast(u8, 0x04) { return X509_SIG_ECDSA_SHA512; }
        }
    } else if len == cast(u64, 7) {
        // ecdsa-with-SHA1: 2a 86 48 ce 3d 04 01
        if buf[off] == cast(u8, 0x2a) && buf[off+1] == cast(u8, 0x86)
           && buf[off+2] == cast(u8, 0x48) && buf[off+3] == cast(u8, 0xce)
           && buf[off+4] == cast(u8, 0x3d) && buf[off+5] == cast(u8, 0x04)
           && buf[off+6] == cast(u8, 0x01) {
            return X509_SIG_ECDSA_SHA1;
        }
    }
    return X509_SIG_UNKNOWN;
}

// Parse the OID out of an AlgorithmIdentifier SEQUENCE.
u16 x509_parse_sig_alg(u8* buf, DerTlv* alg) {
    DerCursor c = der_enter(buf, alg);
    DerTlv oid;
    if !der_read_tlv(&c, &oid) { return X509_SIG_UNKNOWN; }
    if oid.tag != cast(u8, 0x06) { return X509_SIG_UNKNOWN; }
    return x509_oid_to_sig(buf, oid.content, oid.len);
}

// --- time ------------------------------------------------------------------

// Two ASCII decimal digits at buf[p]. Returns -1 if either is not a digit.
i32 der_2d(u8* buf, u64 p) {
    u8 a = buf[p];
    u8 b = buf[p + 1];
    if a < cast(u8, 0x30) || a > cast(u8, 0x39) { return 0 - 1; }
    if b < cast(u8, 0x30) || b > cast(u8, 0x39) { return 0 - 1; }
    return cast(i32, a - cast(u8, 0x30)) * 10 + cast(i32, b - cast(u8, 0x30));
}

// Days from 1970-01-01 to the given proleptic-Gregorian date (m in [1,12]).
i64 days_from_civil(i32 y, i32 m, i32 d) {
    i32 yy = m <= 2 ? y - 1 : y;
    i64 y64 = cast(i64, yy);
    i64 era = (y64 >= 0 ? y64 : y64 - 399) / 400;
    i64 yoe = y64 - era * 400;
    i64 mp = cast(i64, (m + 9) % 12);
    i64 doy = (153 * mp + 2) / 5 + cast(i64, d) - 1;
    i64 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

// Parse a UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ) into
// unix seconds. Only the 'Z' (UTC) form is accepted, matching real certs.
bool x509_parse_time(u8* buf, DerTlv* t, i64* out) {
    u64 p = t.content;
    i32 year = 0;
    if t.tag == cast(u8, 0x17) {
        if t.len != cast(u64, 13) { return false; }
        i32 yy = der_2d(buf, p);
        if yy < 0 { return false; }
        year = yy < 50 ? 2000 + yy : 1900 + yy;
        p = p + 2;
    } else if t.tag == cast(u8, 0x18) {
        if t.len != cast(u64, 15) { return false; }
        i32 hi = der_2d(buf, p);
        i32 lo = der_2d(buf, p + 2);
        if hi < 0 || lo < 0 { return false; }
        year = hi * 100 + lo;
        p = p + 4;
    } else {
        return false;
    }
    i32 mon = der_2d(buf, p);
    i32 day = der_2d(buf, p + 2);
    i32 hh = der_2d(buf, p + 4);
    i32 mm = der_2d(buf, p + 6);
    i32 ss = der_2d(buf, p + 8);
    if mon < 1 || mon > 12 { return false; }
    if day < 1 || day > 31 { return false; }
    if hh > 23 || mm > 59 || ss > 60 { return false; }
    if buf[p + 10] != cast(u8, 0x5a) { return false; }   // trailing 'Z'
    *out = days_from_civil(year, mon, day) * 86400
           + cast(i64, hh) * 3600 + cast(i64, mm) * 60 + cast(i64, ss);
    return true;
}

// --- extensions ------------------------------------------------------------

const i32 X509_EXT_NONE = 0;
const i32 X509_EXT_SAN = 1;
const i32 X509_EXT_BASIC = 2;
const i32 X509_EXT_KEYUSAGE = 3;

// Classify a 3-byte {2.5.29.x} extension OID.
i32 x509_ext_oid_kind(u8* buf, DerTlv* oid) {
    if oid.len != cast(u64, 3) { return X509_EXT_NONE; }
    if buf[oid.content] != cast(u8, 0x55) { return X509_EXT_NONE; }
    if buf[oid.content + 1] != cast(u8, 0x1d) { return X509_EXT_NONE; }
    u8 last = buf[oid.content + 2];
    if last == cast(u8, 0x11) { return X509_EXT_SAN; }
    if last == cast(u8, 0x13) { return X509_EXT_BASIC; }
    if last == cast(u8, 0x0f) { return X509_EXT_KEYUSAGE; }
    return X509_EXT_NONE;
}

// A small non-negative INTEGER (pathLenConstraint). Returns -1 if out of range.
i32 x509_small_int(u8* buf, DerTlv* t) {
    if t.len == cast(u64, 0) || t.len > cast(u64, 2) { return 0 - 1; }
    i32 v = 0;
    for u64 i = 0; i < t.len; i++ { v = (v << 8) | cast(i32, buf[t.content + i]); }
    return v;
}

// basicConstraints ::= SEQUENCE { cA BOOLEAN DEFAULT FALSE, pathLen INTEGER OPTIONAL }
bool x509_parse_basic_constraints(u8* buf, DerTlv* val, X509Cert* out) {
    out.has_basic_constraints = true;
    DerCursor vc = der_enter(buf, val);
    DerTlv seq;
    if !der_read_tlv(&vc, &seq) { return false; }
    if seq.tag != cast(u8, 0x30) { return false; }
    DerCursor sc = der_enter(buf, &seq);
    if sc.pos >= sc.end { out.is_ca = false; return true; }   // empty: cA defaults FALSE
    DerTlv first;
    if !der_read_tlv(&sc, &first) { return false; }
    if first.tag == cast(u8, 0x01) {
        if first.len != cast(u64, 1) { return false; }
        out.is_ca = buf[first.content] != cast(u8, 0);
        if sc.pos < sc.end {
            DerTlv pl;
            if !der_read_tlv(&sc, &pl) { return false; }
            if pl.tag == cast(u8, 0x02) { out.path_len = x509_small_int(buf, &pl); }
        }
    } else if first.tag == cast(u8, 0x02) {
        out.is_ca = false;                        // cA omitted -> FALSE
        out.path_len = x509_small_int(buf, &first);
    }
    return true;
}

// keyUsage ::= BIT STRING. Pack the first two bit-bytes into key_usage.
bool x509_parse_key_usage(u8* buf, DerTlv* val, X509Cert* out) {
    DerCursor vc = der_enter(buf, val);
    DerTlv bs;
    if !der_read_tlv(&vc, &bs) { return false; }
    if bs.tag != cast(u8, 0x03) { return false; }
    if bs.len < cast(u64, 1) { return false; }
    u16 bits = 0;
    if bs.len >= cast(u64, 2) { bits = cast(u16, cast(i32, buf[bs.content + 1]) << 8); }
    if bs.len >= cast(u64, 3) { bits = cast(u16, cast(i32, bits) | cast(i32, buf[bs.content + 2])); }
    out.key_usage = bits;
    out.has_key_usage = true;
    return true;
}

// Walk Extensions ::= [3] EXPLICIT SEQUENCE OF Extension. Only SAN,
// basicConstraints and keyUsage are captured; others are skipped.
bool x509_parse_extensions(u8* buf, DerTlv* ext_explicit, X509Cert* out) {
    DerCursor ec = der_enter(buf, ext_explicit);
    DerTlv seq;
    if !der_read_tlv(&ec, &seq) { return false; }
    if seq.tag != cast(u8, 0x30) { return false; }
    DerCursor sc = der_enter(buf, &seq);
    while sc.pos < sc.end {
        DerTlv e;
        if !der_read_tlv(&sc, &e) { return false; }
        if e.tag != cast(u8, 0x30) { return false; }
        DerCursor ic = der_enter(buf, &e);
        DerTlv oid;
        if !der_read_tlv(&ic, &oid) { return false; }
        if oid.tag != cast(u8, 0x06) { return false; }
        DerTlv nextf;
        if !der_read_tlv(&ic, &nextf) { return false; }
        DerTlv valtlv;
        if nextf.tag == cast(u8, 0x01) {           // critical BOOLEAN present
            if !der_read_tlv(&ic, &valtlv) { return false; }
        } else {
            valtlv = nextf;
        }
        if valtlv.tag != cast(u8, 0x04) { return false; }   // extnValue OCTET STRING
        i32 kind = x509_ext_oid_kind(buf, &oid);
        if kind == X509_EXT_SAN {
            DerCursor gnc = der_enter(buf, &valtlv);
            DerTlv gn;
            if !der_read_tlv(&gnc, &gn) { return false; }
            if gn.tag != cast(u8, 0x30) { return false; }
            out.san.off = gn.content;
            out.san.len = gn.len;
        } else if kind == X509_EXT_BASIC {
            if !x509_parse_basic_constraints(buf, &valtlv, out) { return false; }
        } else if kind == X509_EXT_KEYUSAGE {
            if !x509_parse_key_usage(buf, &valtlv, out) { return false; }
        }
    }
    return true;
}

// Validity ::= SEQUENCE { notBefore Time, notAfter Time }.
bool x509_parse_validity(u8* buf, DerTlv* v, X509Cert* out) {
    DerCursor c = der_enter(buf, v);
    DerTlv nb;
    if !der_read_tlv(&c, &nb) { return false; }
    if !x509_parse_time(buf, &nb, &out.not_before) { return false; }
    DerTlv na;
    if !der_read_tlv(&c, &na) { return false; }
    if !x509_parse_time(buf, &na, &out.not_after) { return false; }
    return true;
}

// Parse the fields of a TBSCertificate.
bool x509_parse_tbs(u8* buf, DerTlv* tbs, X509Cert* out) {
    DerCursor c = der_enter(buf, tbs);

    // version ::= [0] EXPLICIT INTEGER DEFAULT v1  (optional)
    if der_peek_tag(&c) == 0xa0 {
        DerTlv ver;
        if !der_read_tlv(&c, &ver) { return false; }
    }
    // serialNumber INTEGER
    DerTlv serial;
    if !der_read_tlv(&c, &serial) { return false; }
    if serial.tag != cast(u8, 0x02) { return false; }
    // signature AlgorithmIdentifier (inner)
    DerTlv inneralg;
    if !der_read_tlv(&c, &inneralg) { return false; }
    if inneralg.tag != cast(u8, 0x30) { return false; }
    out.tbs_sig_alg_id = x509_parse_sig_alg(buf, &inneralg);
    // issuer Name
    DerTlv issuer;
    if !der_read_tlv(&c, &issuer) { return false; }
    if issuer.tag != cast(u8, 0x30) { return false; }
    out.issuer.off = issuer.hdr;
    out.issuer.len = (issuer.content + issuer.len) - issuer.hdr;
    // validity
    DerTlv validity;
    if !der_read_tlv(&c, &validity) { return false; }
    if validity.tag != cast(u8, 0x30) { return false; }
    if !x509_parse_validity(buf, &validity, out) { return false; }
    // subject Name
    DerTlv subject;
    if !der_read_tlv(&c, &subject) { return false; }
    if subject.tag != cast(u8, 0x30) { return false; }
    out.subject.off = subject.hdr;
    out.subject.len = (subject.content + subject.len) - subject.hdr;
    // subjectPublicKeyInfo
    DerTlv spki;
    if !der_read_tlv(&c, &spki) { return false; }
    if spki.tag != cast(u8, 0x30) { return false; }
    out.spki.off = spki.hdr;
    out.spki.len = (spki.content + spki.len) - spki.hdr;
    // optional issuerUniqueID [1], subjectUniqueID [2], extensions [3]
    while c.pos < c.end {
        DerTlv fld;
        if !der_read_tlv(&c, &fld) { return false; }
        if fld.tag == cast(u8, 0xa3) {
            if !x509_parse_extensions(buf, &fld, out) { return false; }
        }
    }
    return true;
}

}  // private

// Parse a DER Certificate into *out. Returns false on any malformation.
// The buffer must contain exactly one certificate with no trailing bytes.
bool x509_parse(u8* buf, u64 buf_len, X509Cert* out) {
    *out = X509Cert{};
    out.buf = buf;
    out.buf_len = buf_len;
    out.path_len = 0 - 1;

    DerCursor top = DerCursor{ .buf = buf, .pos = 0, .end = buf_len };
    DerTlv cert;
    if !der_read_tlv(&top, &cert) { return false; }
    if cert.tag != cast(u8, 0x30) { return false; }
    if cert.content + cert.len != buf_len { return false; }   // no trailing garbage

    DerCursor cc = der_enter(buf, &cert);

    // tbsCertificate
    DerTlv tbs;
    if !der_read_tlv(&cc, &tbs) { return false; }
    if tbs.tag != cast(u8, 0x30) { return false; }
    out.tbs.off = tbs.hdr;
    out.tbs.len = (tbs.content + tbs.len) - tbs.hdr;
    // signatureAlgorithm
    DerTlv salg;
    if !der_read_tlv(&cc, &salg) { return false; }
    if salg.tag != cast(u8, 0x30) { return false; }
    out.sig_alg.off = salg.hdr;
    out.sig_alg.len = (salg.content + salg.len) - salg.hdr;
    out.sig_alg_id = x509_parse_sig_alg(buf, &salg);
    // signatureValue BIT STRING
    DerTlv sval;
    if !der_read_tlv(&cc, &sval) { return false; }
    if sval.tag != cast(u8, 0x03) { return false; }
    if sval.len < cast(u64, 1) { return false; }
    if buf[sval.content] != cast(u8, 0) { return false; }   // 0 unused bits
    out.sig_val.off = sval.content + 1;
    out.sig_val.len = sval.len - 1;
    if cc.pos != cc.end { return false; }   // no trailing bytes in Certificate

    return x509_parse_tbs(buf, &tbs, out);
}

// --- DN comparison ---------------------------------------------------------

// Byte-exact comparison of two DER ranges (RFC 5280 chain linkage compares
// issuer/subject Names as encoded).
bool x509_range_equal(X509Cert* a, DerRange ra, X509Cert* b, DerRange rb) {
    if ra.len != rb.len { return false; }
    for u64 i = 0; i < ra.len; i++ {
        if a.buf[ra.off + i] != b.buf[rb.off + i] { return false; }
    }
    return true;
}

// child.issuer == parent.subject, byte for byte.
bool x509_issuer_matches(X509Cert* child, X509Cert* parent) {
    return x509_range_equal(child, child.issuer, parent, parent.subject);
}

// --- hostname matching (RFC 6125) ------------------------------------------

private {

u8 ascii_lower(u8 c) {
    if c >= cast(u8, 0x41) && c <= cast(u8, 0x5a) { return cast(u8, cast(i32, c) + 0x20); }
    return c;
}

bool ci_equal(u8* a, i32 alen, u8* b, i32 blen) {
    if alen != blen { return false; }
    for i32 i = 0; i < alen; i++ {
        if ascii_lower(a[i]) != ascii_lower(b[i]) { return false; }
    }
    return true;
}

}  // private

// Match one SAN dNSName pattern against a host. A single leftmost '*' matches
// exactly one non-empty label; partial-label wildcards (f*o) are rejected;
// the wildcard suffix must span at least two labels (so *.com never matches);
// embedded NULs reject; comparison is ASCII case-insensitive. No CN fallback.
bool x509_dnsname_match(u8* pat, i32 patlen, u8* host, i32 hostlen) {
    if patlen <= 0 || hostlen <= 0 { return false; }
    for i32 i = 0; i < patlen; i++ { if pat[i] == cast(u8, 0) { return false; } }
    for i32 i = 0; i < hostlen; i++ { if host[i] == cast(u8, 0) { return false; } }

    i32 stars = 0;
    i32 star_at = 0 - 1;
    for i32 i = 0; i < patlen; i++ {
        if pat[i] == cast(u8, 0x2a) { stars++; star_at = i; }
    }
    if stars == 0 { return ci_equal(pat, patlen, host, hostlen); }
    if stars > 1 { return false; }
    if star_at != 0 { return false; }                 // wildcard not leftmost
    if patlen < 2 || pat[1] != cast(u8, 0x2e) { return false; }  // must be "*."

    u8* suf = pat + 1;                                 // ".rest"
    i32 suflen = patlen - 1;
    i32 sufdots = 0;
    for i32 i = 0; i < suflen; i++ { if suf[i] == cast(u8, 0x2e) { sufdots++; } }
    if sufdots < 2 { return false; }                   // require >= 2 labels

    i32 hdot = 0 - 1;
    for i32 i = 0; i < hostlen; i++ {
        if host[i] == cast(u8, 0x2e) { hdot = i; break; }
    }
    if hdot <= 0 { return false; }                     // no / empty first label
    return ci_equal(suf, suflen, host + hdot, hostlen - hdot);
}

// True if host matches any dNSName in the leaf's subjectAltName.
bool x509_match_hostname(X509Cert* leaf, u8* host, i32 hostlen) {
    if leaf.san.len == cast(u64, 0) { return false; }
    DerCursor c = DerCursor{ .buf = leaf.buf, .pos = leaf.san.off,
                             .end = leaf.san.off + leaf.san.len };
    while c.pos < c.end {
        DerTlv gn;
        if !der_read_tlv(&c, &gn) { return false; }
        if gn.tag == cast(u8, 0x82) {                  // dNSName [2] IMPLICIT
            if x509_dnsname_match(leaf.buf + gn.content, cast(i32, gn.len), host, hostlen) {
                return true;
            }
        }
    }
    return false;
}

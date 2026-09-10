// bigint.mc — arbitrary-precision integers in base 1e9.
//
// Pure sign-magnitude bignum over little-endian u32 limbs, each in
// 0 .. 999_999_999. The VM layer wraps results into GC_BIGINT cells.
// See doc/DESIGN_bigint.md.

import str;

const u64 BN_BASE = 1000000000;   // 1e9

// Owned little-endian limbs; n == 0 means zero. `neg` is false for zero.
struct BigNum {
    bool neg;
    u32* limbs;
    i32 n;
}

private BigNum bn_zero() {
    BigNum r;
    r.neg = false;
    r.limbs = null;
    r.n = 0;
    return r;
}

void bn_free(BigNum* a) {
    if a.limbs != null { free(a.limbs); }
    a.limbs = null;
    a.n = 0;
}

// Drops leading (most-significant) zero limbs; normalizes -0 to +0.
private void bn_trim(BigNum* a) {
    while a.n > 0 && *(a.limbs + a.n - 1) == 0 { a.n--; }
    if a.n == 0 { a.neg = false; }
}

private u32* bn_alloc(i32 n) {
    u32* p = alloc<u32>(n > 0 ? n : 1);
    for i32 i = 0; i < n; i++ { *(p + i) = 0; }
    return p;
}

BigNum bn_copy(BigNum a) {
    BigNum r;
    r.neg = a.neg;
    r.n = a.n;
    r.limbs = bn_alloc(a.n);
    for i32 i = 0; i < a.n; i++ { *(r.limbs + i) = *(a.limbs + i); }
    return r;
}

BigNum bn_from_i64(i64 v) {
    BigNum r = bn_zero();
    if v == 0 { return r; }
    u64 m;
    if v < 0 { r.neg = true; m = cast(u64, -v); } else { m = cast(u64, v); }
    u32[3] tmp;
    i32 n = 0;
    while m > 0 {
        tmp[n] = cast(u32, m % BN_BASE);
        m = m / BN_BASE;
        n++;
    }
    r.limbs = bn_alloc(n);
    r.n = n;
    for i32 i = 0; i < n; i++ { *(r.limbs + i) = tmp[i]; }
    return r;
}

// --- magnitude helpers (ignore sign) ---------------------------------

// Compares magnitudes: -1 if |a|<|b|, 0 if equal, 1 if greater.
private i32 mag_cmp(BigNum a, BigNum b) {
    if a.n != b.n { return a.n < b.n ? -1 : 1; }
    for i32 i = a.n - 1; i >= 0; i-- {
        u32 x = *(a.limbs + i);
        u32 y = *(b.limbs + i);
        if x != y { return x < y ? -1 : 1; }
    }
    return 0;
}

private BigNum mag_add(BigNum a, BigNum b) {
    i32 n = a.n > b.n ? a.n : b.n;
    BigNum r;
    r.neg = false;
    r.limbs = bn_alloc(n + 1);
    u64 carry = 0;
    for i32 i = 0; i < n; i++ {
        u64 s = carry;
        if i < a.n { s += *(a.limbs + i); }
        if i < b.n { s += *(b.limbs + i); }
        *(r.limbs + i) = cast(u32, s % BN_BASE);
        carry = s / BN_BASE;
    }
    *(r.limbs + n) = cast(u32, carry);
    r.n = n + 1;
    bn_trim(&r);
    return r;
}

// |a| - |b|, requires |a| >= |b|.
private BigNum mag_sub(BigNum a, BigNum b) {
    BigNum r;
    r.neg = false;
    r.limbs = bn_alloc(a.n);
    r.n = a.n;
    i64 borrow = 0;
    for i32 i = 0; i < a.n; i++ {
        i64 d = cast(i64, *(a.limbs + i)) - borrow;
        if i < b.n { d -= *(b.limbs + i); }
        if d < 0 { d += cast(i64, BN_BASE); borrow = 1; } else { borrow = 0; }
        *(r.limbs + i) = cast(u32, d);
    }
    bn_trim(&r);
    return r;
}

private BigNum mag_mul(BigNum a, BigNum b) {
    BigNum r;
    r.neg = false;
    if a.n == 0 || b.n == 0 { r.limbs = null; r.n = 0; return r; }
    r.limbs = bn_alloc(a.n + b.n);
    r.n = a.n + b.n;
    for i32 i = 0; i < a.n; i++ {
        u64 carry = 0;
        u64 ai = *(a.limbs + i);
        for i32 j = 0; j < b.n; j++ {
            u64 cur = cast(u64, *(r.limbs + i + j)) + ai * *(b.limbs + j) + carry;
            *(r.limbs + i + j) = cast(u32, cur % BN_BASE);
            carry = cur / BN_BASE;
        }
        *(r.limbs + i + b.n) += cast(u32, carry);
    }
    bn_trim(&r);
    return r;
}

// Multiplies a magnitude by a single base-1e9 digit d (0..BN_BASE-1).
private BigNum mag_mul_small(BigNum a, u64 d) {
    BigNum r;
    r.neg = false;
    if a.n == 0 || d == 0 { r.limbs = null; r.n = 0; return r; }
    r.limbs = bn_alloc(a.n + 1);
    r.n = a.n + 1;
    u64 carry = 0;
    for i32 i = 0; i < a.n; i++ {
        u64 cur = cast(u64, *(a.limbs + i)) * d + carry;
        *(r.limbs + i) = cast(u32, cur % BN_BASE);
        carry = cur / BN_BASE;
    }
    *(r.limbs + a.n) = cast(u32, carry);
    bn_trim(&r);
    return r;
}

// Long division of magnitudes: q = |a|/|b|, *rem = |a|%|b|. b != 0.
private BigNum mag_divmod(BigNum a, BigNum b, BigNum* rem) {
    BigNum q;
    q.neg = false;
    q.limbs = bn_alloc(a.n > 0 ? a.n : 1);
    q.n = a.n;
    BigNum r = bn_zero();
    for i32 i = a.n - 1; i >= 0; i-- {
        // r = r * BN_BASE + a.limbs[i]  (shift up one limb, add digit)
        u32* nl = bn_alloc(r.n + 1);
        for i32 k = 0; k < r.n; k++ { *(nl + k + 1) = *(r.limbs + k); }
        *(nl + 0) = *(a.limbs + i);
        if r.limbs != null { free(r.limbs); }
        r.limbs = nl;
        r.n = r.n + 1;
        bn_trim(&r);
        // largest digit qd with |b| * qd <= r
        u64 lo = 0;
        u64 hi = BN_BASE - 1;
        u64 qd = 0;
        while lo <= hi {
            u64 mid = (lo + hi) / 2;
            BigNum t = mag_mul_small(b, mid);
            i32 c = mag_cmp(t, r);
            bn_free(&t);
            if c <= 0 { qd = mid; lo = mid + 1; } else {
                if mid == 0 { break; }
                hi = mid - 1;
            }
        }
        *(q.limbs + i) = cast(u32, qd);
        if qd > 0 {
            BigNum t = mag_mul_small(b, qd);
            BigNum nr = mag_sub(r, t);
            bn_free(&t);
            bn_free(&r);
            r = nr;
        }
    }
    bn_trim(&q);
    *rem = r;
    return q;
}

// --- signed operations ----------------------------------------------

i32 bn_cmp(BigNum a, BigNum b) {
    if a.neg != b.neg { return a.neg ? -1 : 1; }
    i32 c = mag_cmp(a, b);
    return a.neg ? -c : c;
}

BigNum bn_add(BigNum a, BigNum b) {
    if a.neg == b.neg {
        BigNum r = mag_add(a, b);
        r.neg = a.neg;
        bn_trim(&r);
        return r;
    }
    i32 c = mag_cmp(a, b);
    if c == 0 { return bn_zero(); }
    BigNum r;
    if c > 0 { r = mag_sub(a, b); r.neg = a.neg; }
    else { r = mag_sub(b, a); r.neg = b.neg; }
    bn_trim(&r);
    return r;
}

BigNum bn_neg(BigNum a) {
    BigNum r = bn_copy(a);
    if r.n > 0 { r.neg = !r.neg; }
    return r;
}

BigNum bn_sub(BigNum a, BigNum b) {
    BigNum nb = bn_neg(b);
    BigNum r = bn_add(a, nb);
    bn_free(&nb);
    return r;
}

BigNum bn_mul(BigNum a, BigNum b) {
    BigNum r = mag_mul(a, b);
    r.neg = (a.neg != b.neg) && r.n > 0;
    return r;
}

// Quotient truncates toward zero. *ok is false on division by zero.
BigNum bn_divmod(BigNum a, BigNum b, BigNum* rem, bool* ok) {
    if b.n == 0 { *ok = false; *rem = bn_zero(); return bn_zero(); }
    *ok = true;
    BigNum r;
    BigNum q = mag_divmod(a, b, &r);
    q.neg = (a.neg != b.neg) && q.n > 0;
    r.neg = a.neg && r.n > 0;   // remainder takes the dividend's sign
    *rem = r;
    return q;
}

// --- bitwise ---------------------------------------------------------
//
// The limbs are base 1e9, which says nothing about bits, so these convert
// to base 2^32, work there, and convert back. A negative value is read as
// its infinite two's complement, which is how the language defines the
// bitwise operators over integers of any size.

const u64 BN_WORD = 4294967296;   // 2^32

// The magnitude in base 2^32, little-endian. Owned; free it.
private u32* bn_to_words(BigNum a, i32* out_n) {
    i32 cn = a.n;
    u32* cur = bn_alloc(cn > 0 ? cn : 1);
    for i32 i = 0; i < cn; i++ { *(cur + i) = *(a.limbs + i); }
    i32 cap = cn + 2;
    u32* w = bn_alloc(cap);
    i32 wn = 0;
    // local copies: `%` by a const of this size miscompiles, see
    // ../lang/doc/BUG_u64_mod_const_over_32_bits.md
    u64 word = BN_WORD;
    u64 base = BN_BASE;
    while cn > 0 {
        // divide the whole number by 2^32; the remainder is the next word
        u64 rem = 0;
        for i32 i = cn - 1; i >= 0; i-- {
            u64 v = rem * base + cast(u64, *(cur + i));
            *(cur + i) = cast(u32, v / word);
            rem = v % word;
        }
        if wn < cap { *(w + wn) = cast(u32, rem); }
        wn++;
        while cn > 0 && *(cur + cn - 1) == 0 { cn--; }
    }
    free(cur);
    *out_n = wn;
    return w;
}

// A base-2^32 magnitude back into base 1e9.
private BigNum bn_from_words(u32* w, i32 wn, bool neg) {
    BigNum r = bn_zero();
    i32 cap = wn * 2 + 2;
    r.limbs = bn_alloc(cap);
    r.n = 0;
    u64 word = BN_WORD;
    u64 base = BN_BASE;
    for i32 i = wn - 1; i >= 0; i-- {
        // r = r * 2^32 + w[i]
        u64 carry = cast(u64, *(w + i));
        for i32 j = 0; j < r.n; j++ {
            u64 v = cast(u64, *(r.limbs + j)) * word + carry;
            *(r.limbs + j) = cast(u32, v % base);
            carry = v / base;
        }
        while carry > 0 && r.n < cap {
            *(r.limbs + r.n) = cast(u32, carry % base);
            carry = carry / base;
            r.n++;
        }
    }
    r.neg = neg;
    bn_trim(&r);
    return r;
}

// Turns a magnitude into its two's complement over `n` words, in place.
private void words_negate(u32* w, i32 n) {
    u64 word = BN_WORD;
    u64 carry = 1;
    for i32 i = 0; i < n; i++ {
        u64 v = cast(u64, ~(*(w + i))) + carry;
        *(w + i) = cast(u32, v % word);
        carry = v / word;
    }
}

// The magnitude of `a` widened to `n` words, as two's complement when it
// is negative. Owned; free it.
private u32* bn_words_signed(BigNum a, i32 n) {
    i32 an = 0;
    u32* aw = bn_to_words(a, &an);
    u32* out = bn_alloc(n);
    for i32 i = 0; i < n; i++ { *(out + i) = i < an ? *(aw + i) : 0; }
    free(aw);
    if a.neg { words_negate(out, n); }
    return out;
}

// kind: 0 and, 1 or, 2 xor
private BigNum bn_bitop(BigNum a, BigNum b, i32 kind) {
    i32 an = 0;
    i32 bn2 = 0;
    u32* aw0 = bn_to_words(a, &an);
    u32* bw0 = bn_to_words(b, &bn2);
    free(aw0);
    free(bw0);
    // one word of headroom, so the sign bit of the result is its own
    i32 n = (an > bn2 ? an : bn2) + 1;
    u32* x = bn_words_signed(a, n);
    u32* y = bn_words_signed(b, n);
    for i32 i = 0; i < n; i++ {
        if kind == 0 { *(x + i) = *(x + i) & *(y + i); }
        else if kind == 1 { *(x + i) = *(x + i) | *(y + i); }
        else { *(x + i) = *(x + i) ^ *(y + i); }
    }
    free(y);
    bool neg = (*(x + n - 1) >> 31) != 0;
    if neg { words_negate(x, n); }
    BigNum r = bn_from_words(x, n, neg);
    free(x);
    return r;
}

BigNum bn_and(BigNum a, BigNum b) { return bn_bitop(a, b, 0); }
BigNum bn_or(BigNum a, BigNum b) { return bn_bitop(a, b, 1); }
BigNum bn_xor(BigNum a, BigNum b) { return bn_bitop(a, b, 2); }

// ~a is -(a + 1), which needs no bits at all.
BigNum bn_not(BigNum a) {
    BigNum one = bn_from_i64(1);
    BigNum plus = bn_add(a, one);
    BigNum r = bn_neg(plus);
    bn_free(&plus);
    bn_free(&one);
    return r;
}

// 2^n, for the shifts.
private BigNum bn_pow2(i64 n) {
    BigNum two = bn_from_i64(2);
    BigNum e = bn_from_i64(n);
    bool ok = true;
    BigNum r = bn_pow(two, e, &ok);
    bn_free(&e);
    bn_free(&two);
    return r;
}

// a << n, n >= 0.
BigNum bn_shl(BigNum a, i64 n) {
    if a.n == 0 || n == 0 { return bn_copy(a); }
    BigNum p = bn_pow2(n);
    BigNum r = bn_mul(a, p);
    bn_free(&p);
    return r;
}

// a >> n, n >= 0. The shift floors, so a negative value rounds away from
// zero rather than toward it: -9n >> 2n is -3n, not -2n.
BigNum bn_shr(BigNum a, i64 n) {
    if a.n == 0 || n == 0 { return bn_copy(a); }
    BigNum p = bn_pow2(n);
    BigNum rem;
    bool ok = true;
    BigNum q = bn_divmod(a, p, &rem, &ok);
    bool round_down = a.neg && rem.n > 0;
    bn_free(&rem);
    bn_free(&p);
    if !round_down { return q; }
    BigNum one = bn_from_i64(1);
    BigNum r = bn_sub(q, one);
    bn_free(&one);
    bn_free(&q);
    return r;
}

// a ** e, e >= 0. *ok is false for a negative exponent.
BigNum bn_pow(BigNum a, BigNum e, bool* ok) {
    if e.neg { *ok = false; return bn_zero(); }
    *ok = true;
    BigNum result = bn_from_i64(1);
    BigNum base = bn_copy(a);
    BigNum exp = bn_copy(e);
    BigNum two = bn_from_i64(2);
    while exp.n > 0 {
        BigNum rem;
        bool dok;
        BigNum half = bn_divmod(exp, two, &rem, &dok);
        bool odd = rem.n > 0;
        bn_free(&rem);
        if odd {
            BigNum nr = bn_mul(result, base);
            bn_free(&result);
            result = nr;
        }
        bn_free(&exp);
        exp = half;
        if exp.n > 0 {
            BigNum sq = bn_mul(base, base);
            bn_free(&base);
            base = sq;
        }
    }
    bn_free(&base);
    bn_free(&exp);
    bn_free(&two);
    return result;
}

// --- conversions -----------------------------------------------------

// Parses an optionally-signed decimal integer. *ok false on bad input.
private i32 bn_digit_val(u8 c) {
    if c >= '0' && c <= '9' { return cast(i32, c) - cast(i32, '0'); }
    if c >= 'a' && c <= 'f' { return cast(i32, c) - cast(i32, 'a') + 10; }
    if c >= 'A' && c <= 'F' { return cast(i32, c) - cast(i32, 'A') + 10; }
    return 0 - 1;
}

// Digits in base 2, 8 or 16, accumulated as value = value * radix + digit.
private BigNum bn_from_digits(str s, i32 i, i32 end, i32 radix, bool* ok) {
    BigNum r = bn_from_i64(cast(i64, 0));
    BigNum rad = bn_from_i64(cast(i64, radix));
    bool any = false;
    for i32 k = i; k < end; k++ {
        i32 d = bn_digit_val(*(s.data + k));
        if d < 0 || d >= radix { *ok = false; break; }
        any = true;
        BigNum t = bn_mul(r, rad);
        BigNum dv = bn_from_i64(cast(i64, d));
        BigNum sum = bn_add(t, dv);
        bn_free(&r);
        bn_free(&t);
        bn_free(&dv);
        r = sum;
    }
    bn_free(&rad);
    if !any { *ok = false; }
    if !*ok {
        bn_free(&r);
        return bn_zero();
    }
    return r;
}

BigNum bn_from_str(str s, bool* ok) {
    *ok = true;
    i32 i = 0;
    i32 end = s.len;
    while i < end && (*(s.data + i) == ' ' || *(s.data + i) == '\t'
        || *(s.data + i) == '\n' || *(s.data + i) == '\r') { i++; }
    while end > i && (*(s.data + end - 1) == ' ' || *(s.data + end - 1) == '\t'
        || *(s.data + end - 1) == '\n' || *(s.data + end - 1) == '\r') { end--; }
    bool neg = false;
    if i < end && (*(s.data + i) == '+' || *(s.data + i) == '-') {
        neg = *(s.data + i) == '-';
        i++;
    }
    if i >= end { *ok = false; return bn_zero(); }
    // a 0x / 0b / 0o prefix selects the radix; those forms take no sign
    if !neg && end - i > 2 && *(s.data + i) == '0' {
        u8 p = *(s.data + i + 1);
        i32 radix = 0;
        if p == 'x' || p == 'X' { radix = 16; }
        else if p == 'b' || p == 'B' { radix = 2; }
        else if p == 'o' || p == 'O' { radix = 8; }
        if radix != 0 { return bn_from_digits(s, i + 2, end, radix, ok); }
    }
    i32 ndig = end - i;
    // limbs = ceil(ndig / 9)
    i32 nlimbs = (ndig + 8) / 9;
    BigNum r;
    r.neg = false;
    r.limbs = bn_alloc(nlimbs);
    r.n = nlimbs;
    // fill limbs from the least-significant end, 9 digits at a time
    i32 li = 0;
    i32 pos = end;
    while pos > i {
        i32 lo = pos - 9;
        if lo < i { lo = i; }
        u32 v = 0;
        for i32 k = lo; k < pos; k++ {
            u8 c = *(s.data + k);
            if c < '0' || c > '9' { *ok = false; bn_free(&r); return bn_zero(); }
            v = v * 10 + (c - '0');
        }
        *(r.limbs + li) = v;
        li++;
        pos = lo;
    }
    bn_trim(&r);
    if r.n > 0 { r.neg = neg; }
    return r;
}

// Owned decimal string.
string bn_to_str(BigNum a) {
    if a.n == 0 { return format("{}", 0); }
    str_buf sb;
    str_buf_init(&sb);
    if a.neg { str_buf_add(&sb, "-"); }
    // most-significant limb without padding
    string top = format("{}", *(a.limbs + a.n - 1));
    str_buf_add(&sb, top);
    free(top);
    // remaining limbs zero-padded to 9 digits
    for i32 i = a.n - 2; i >= 0; i-- {
        u32 v = *(a.limbs + i);
        u8[9] buf;
        for i32 k = 8; k >= 0; k-- { buf[k] = cast(u8, '0' + (v % 10)); v = v / 10; }
        str piece;
        piece.data = &buf[0];
        piece.len = 9;
        str_buf_add(&sb, piece);
    }
    string out = string(str_buf_to_str(&sb));
    str_buf_free(&sb);
    return out;
}

f64 bn_to_f64(BigNum a) {
    f64 r = 0.0;
    f64 base = cast(f64, BN_BASE);
    for i32 i = a.n - 1; i >= 0; i-- {
        r = r * base + cast(f64, *(a.limbs + i));
    }
    return a.neg ? -r : r;
}

bool bn_is_zero(BigNum a) { return a.n == 0; }

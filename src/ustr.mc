// ustr.mc — UTF-16 code-unit view over UTF-8/WTF-8 byte storage.
//
// JS strings are UTF-16 code-unit sequences; tsmc stores their bytes as
// UTF-8. These pure helpers translate between the two: counting units,
// reading a unit or code point, and building a substring for a unit
// range. Lone surrogates round-trip as WTF-8 (the surrogate value in a
// 3-byte sequence). See doc/DESIGN_string.md.

import str;

// Decodes one code point at byte offset `off`. Sets *nbytes to its
// byte length. Lenient: a stray continuation or truncated sequence is
// returned as a single raw byte. WTF-8 surrogate sequences decode to
// their surrogate value.
i32 utf8_decode(str s, i32 off, i32* nbytes) {
    u8 b0 = *(s.data + off);
    if b0 < 0x80 {
        *nbytes = 1;
        return cast(i32, b0);
    }
    if b0 >= 0xF0 && off + 3 < s.len {
        i32 b1 = cast(i32, *(s.data + off + 1));
        i32 b2 = cast(i32, *(s.data + off + 2));
        i32 b3 = cast(i32, *(s.data + off + 3));
        *nbytes = 4;
        return ((cast(i32, b0) & 0x07) << 18) | ((b1 & 0x3F) << 12)
            | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
    }
    if b0 >= 0xE0 && off + 2 < s.len {
        i32 b1 = cast(i32, *(s.data + off + 1));
        i32 b2 = cast(i32, *(s.data + off + 2));
        *nbytes = 3;
        return ((cast(i32, b0) & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
    }
    if b0 >= 0xC0 && off + 1 < s.len {
        i32 b1 = cast(i32, *(s.data + off + 1));
        *nbytes = 2;
        return ((cast(i32, b0) & 0x1F) << 6) | (b1 & 0x3F);
    }
    *nbytes = 1;
    return cast(i32, b0);
}

// UTF-16 code units a code point occupies (astral = 2).
private i32 cp_units(i32 cp) {
    return cp > 0xFFFF ? 2 : 1;
}

// Number of UTF-16 code units in the string.
i32 u16_count(str s) {
    i32 units = 0;
    i32 off = 0;
    while off < s.len {
        i32 n;
        i32 cp = utf8_decode(s, off, &n);
        units += cp_units(cp);
        off += n;
    }
    return units;
}

// The UTF-16 code unit at index `idx`, or -1 if out of range. Astral
// code points expose a high then low surrogate.
i32 u16_unit_at(str s, i32 idx) {
    if idx < 0 { return -1; }
    i32 u = 0;
    i32 off = 0;
    while off < s.len {
        i32 n;
        i32 cp = utf8_decode(s, off, &n);
        i32 w = cp_units(cp);
        if idx < u + w {
            if w == 1 { return cp; }
            i32 v = cp - 0x10000;
            if idx == u { return 0xD800 + (v >> 10); }
            return 0xDC00 + (v & 0x3FF);
        }
        u += w;
        off += n;
    }
    return -1;
}

// Byte offset of the `idx`-th UTF-16 unit, clamped to [0, s.len]. When
// idx falls on the low half of an astral pair the code point's start
// offset is returned (callers that split there use u16_slice_into).
i32 u16_offset(str s, i32 idx) {
    if idx <= 0 { return 0; }
    i32 u = 0;
    i32 off = 0;
    while off < s.len {
        if u >= idx { return off; }
        i32 n;
        i32 cp = utf8_decode(s, off, &n);
        u += cp_units(cp);
        off += n;
    }
    return s.len;
}

// Converts a byte offset to its UTF-16 unit index.
i32 u16_byte_to_unit(str s, i32 byte_off) {
    i32 u = 0;
    i32 off = 0;
    while off < byte_off && off < s.len {
        i32 n;
        i32 cp = utf8_decode(s, off, &n);
        u += cp_units(cp);
        off += n;
    }
    return u;
}

// Appends a code point as UTF-8; a surrogate value becomes WTF-8.
void wtf8_put_cp(str_buf* sb, i32 cp) {
    u8[4] buf;
    i32 n = 0;
    if cp < 0x80 {
        buf[0] = cast(u8, cp);
        n = 1;
    } else if cp < 0x800 {
        buf[0] = cast(u8, 0xC0 | (cp >> 6));
        buf[1] = cast(u8, 0x80 | (cp & 0x3F));
        n = 2;
    } else if cp < 0x10000 {
        buf[0] = cast(u8, 0xE0 | (cp >> 12));
        buf[1] = cast(u8, 0x80 | ((cp >> 6) & 0x3F));
        buf[2] = cast(u8, 0x80 | (cp & 0x3F));
        n = 3;
    } else {
        buf[0] = cast(u8, 0xF0 | (cp >> 18));
        buf[1] = cast(u8, 0x80 | ((cp >> 12) & 0x3F));
        buf[2] = cast(u8, 0x80 | ((cp >> 6) & 0x3F));
        buf[3] = cast(u8, 0x80 | (cp & 0x3F));
        n = 4;
    }
    str chunk;
    chunk.data = &buf[0];
    chunk.len = n;
    str_buf_add(sb, chunk);
}

// True if the bytes contain a WTF-8 lone-surrogate sequence
// (0xED followed by 0xA0..0xBF encodes U+D800..U+DFFF).
bool wtf8_has_surrogate(str s) {
    for i32 i = 0; i + 1 < s.len; i++ {
        if *(s.data + i) == 0xED && *(s.data + i + 1) >= 0xA0 { return true; }
    }
    return false;
}

// Copies `s` into `sb`, replacing WTF-8 lone-surrogate sequences with
// U+FFFD — for writing to a strict UTF-8 sink.
void wtf8_sanitize_into(str_buf* sb, str s) {
    i32 off = 0;
    while off < s.len {
        u8 b = *(s.data + off);
        if b == 0xED && off + 3 <= s.len && *(s.data + off + 1) >= 0xA0 {
            wtf8_put_cp(sb, 0xFFFD);
            off += 3;
        } else {
            str one;
            one.data = s.data + off;
            one.len = 1;
            str_buf_add(sb, one);
            off++;
        }
    }
}

// Appends the UTF-16 unit range [start, end) of `s` as bytes. A range
// boundary inside an astral pair emits a lone surrogate as WTF-8.
void u16_slice_into(str_buf* sb, str s, i32 start, i32 end) {
    if start < 0 { start = 0; }
    i32 u = 0;
    i32 off = 0;
    while off < s.len && u < end {
        i32 n;
        i32 cp = utf8_decode(s, off, &n);
        i32 w = cp_units(cp);
        if u + w <= start {
            // wholly before the range
        } else {
            i32 lo = u < start ? start : u;
            i32 hi = (u + w) > end ? end : (u + w);
            if hi - lo == w {
                str chunk;
                chunk.data = s.data + off;
                chunk.len = n;
                str_buf_add(sb, chunk);
            } else {
                i32 v = cp - 0x10000;
                i32 high = 0xD800 + (v >> 10);
                i32 low = 0xDC00 + (v & 0x3FF);
                for i32 k = lo; k < hi; k++ {
                    wtf8_put_cp(sb, (k - u) == 0 ? high : low);
                }
            }
        }
        u += w;
        off += n;
    }
}

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

// --- cursor-resumed lookups --------------------------------------------
//
// A cursor is a unit index and the byte offset of the code point that
// starts there. A caller keeps one per string, starting at (0, 0), and
// a lookup walks from it in either direction, so a loop over a string
// costs the distance moved rather than the distance from the start.

// Moves the cursor to the code point holding unit `idx`, or to the end
// of the string when idx is past the last unit.
private void u16_seek(str s, i32 idx, i32* cu, i32* co) {
    if idx < 0 { idx = 0; }
    while *cu > idx && *co > 0 {
        // back over one code point: the lead byte before the continuation
        // bytes, unless the forward decoder would not have read it as one
        // sequence, in which case the last byte stands on its own
        i32 last = *co - 1;
        i32 lead = last;
        while lead > 0 && (*(s.data + lead) & 0xC0) == 0x80 { lead--; }
        i32 n;
        i32 cp = utf8_decode(s, lead, &n);
        if lead + n != *co {
            lead = last;
            cp = utf8_decode(s, lead, &n);
        }
        *co = lead;
        *cu -= cp_units(cp);
    }
    while *co < s.len {
        i32 n;
        i32 cp = utf8_decode(s, *co, &n);
        i32 w = cp_units(cp);
        if idx < *cu + w { return; }
        *cu += w;
        *co += n;
    }
}

// The UTF-16 code unit at `idx`, resumed from the cursor; -1 when out of
// range. Astral code points expose a high then low surrogate.
i32 u16_unit_at_cur(str s, i32 idx, i32* cu, i32* co) {
    if idx < 0 { return -1; }
    u16_seek(s, idx, cu, co);
    if *co >= s.len { return -1; }
    i32 n;
    i32 cp = utf8_decode(s, *co, &n);
    if cp_units(cp) == 1 { return cp; }
    i32 v = cp - 0x10000;
    if idx == *cu { return 0xD800 + (v >> 10); }
    return 0xDC00 + (v & 0x3FF);
}

// Byte offset of the `idx`-th UTF-16 unit, resumed from the cursor and
// clamped to [0, s.len]. An idx on the low half of an astral pair maps
// past the pair, the first boundary at or after it.
i32 u16_offset_cur(str s, i32 idx, i32* cu, i32* co) {
    if idx <= 0 { return 0; }
    u16_seek(s, idx, cu, co);
    if *co >= s.len { return s.len; }
    if idx == *cu { return *co; }
    i32 n;
    ignore utf8_decode(s, *co, &n);
    return *co + n;
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

// The UTF-16 code unit at index `idx`, or -1 if out of range, walked
// from the start.
i32 u16_unit_at(str s, i32 idx) {
    i32 cu = 0;
    i32 co = 0;
    return u16_unit_at_cur(s, idx, &cu, &co);
}

// Byte offset of the `idx`-th UTF-16 unit, walked from the start.
i32 u16_offset(str s, i32 idx) {
    i32 cu = 0;
    i32 co = 0;
    return u16_offset_cur(s, idx, &cu, &co);
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

// Rewrites each adjacent high+low surrogate pair, two WTF-8 sequences,
// as the astral code point they spell, one UTF-8 sequence, in place.
// Returns the new byte length. In UTF-16 terms the pair and the code
// point are the same string, and equality compares bytes, so a string
// assembled from halves has to end up with the same bytes as the whole.
i32 wtf8_merge_pairs(u8* data, i32 len) {
    i32 r = 0;
    i32 w = 0;
    while r < len {
        if r + 5 < len && *(data + r) == 0xED && (*(data + r + 1) & 0xF0) == 0xA0
            && *(data + r + 3) == 0xED && (*(data + r + 4) & 0xF0) == 0xB0 {
            i32 hi = 0xD000 | ((cast(i32, *(data + r + 1)) & 0x3F) << 6) | (cast(i32, *(data + r + 2)) & 0x3F);
            i32 lo = 0xD000 | ((cast(i32, *(data + r + 4)) & 0x3F) << 6) | (cast(i32, *(data + r + 5)) & 0x3F);
            i32 cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
            *(data + w) = cast(u8, 0xF0 | (cp >> 18));
            *(data + w + 1) = cast(u8, 0x80 | ((cp >> 12) & 0x3F));
            *(data + w + 2) = cast(u8, 0x80 | ((cp >> 6) & 0x3F));
            *(data + w + 3) = cast(u8, 0x80 | (cp & 0x3F));
            r += 6;
            w += 4;
        } else {
            if w != r { *(data + w) = *(data + r); }
            r++;
            w++;
        }
    }
    return w;
}

// True when a ends with a high surrogate and b starts with a low one:
// their concatenation spells an astral code point.
bool wtf8_pair_at_junction(str a, str b) {
    if a.len < 3 || b.len < 3 { return false; }
    return *(a.data + a.len - 3) == 0xED && (*(a.data + a.len - 2) & 0xF0) == 0xA0
        && *(b.data) == 0xED && (*(b.data + 1) & 0xF0) == 0xB0;
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

// Appends the UTF-16 unit range [start, end) of `s` as bytes, resumed
// from the cursor, which is left at `start`. A range boundary inside an
// astral pair emits a lone surrogate as WTF-8.
void u16_slice_into_cur(str_buf* sb, str s, i32 start, i32 end, i32* cu, i32* co) {
    if start < 0 { start = 0; }
    if end <= start { return; }
    u16_seek(s, start, cu, co);
    i32 u = *cu;
    i32 off = *co;
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

// The unit range [start, end) of `s`, walked from the start.
void u16_slice_into(str_buf* sb, str s, i32 start, i32 end) {
    i32 cu = 0;
    i32 co = 0;
    u16_slice_into_cur(sb, s, start, end, &cu, &co);
}

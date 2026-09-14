// numparse.mc — decimal text to the nearest double.
//
// One conversion, shared by the lexer (numeric literals) and the runtime
// (Number(str), parseFloat, JSON numbers), because it has to be correctly
// rounded and that is not something to write twice. Scaling a mantissa by a
// power of ten in doubles rounds twice: the mantissa first, when it needs more
// than 53 bits, and the product after. Two roundings land a unit or two away,
// which showed up as `999999999999999.9 === 1e15` and a MAX_VALUE literal that
// was not MAX_VALUE.

import str;
import math;

// The double nearest the value the text spells, ties to even, as every IEEE
// operation rounds. The text is what a scanner has already accepted: digits with
// an optional point and an optional exponent, and the `_` separators a literal
// may carry, which are removed here. A sign belongs to the caller.
f64 dec_to_f64(str s) {
    // The conversion wants a terminated string. Numbers are short, so the
    // buffer covers them; a literal with hundreds of digits gets one allocation.
    u8[64] small;
    u8* buf = &small[0];
    u8* owned = null;
    if s.len + 1 > 64 {
        owned = alloc<u8>(s.len + 1);
        buf = owned;
    }
    i32 n = 0;
    for i32 i = 0; i < s.len; i++ {
        u8 c = *(s.data + i);
        if c != '_' {
            *(buf + n) = c;
            n++;
        }
    }
    *(buf + n) = 0;
    f64 v = strtod(buf, null);
    if owned != null { free(owned); }
    return v;
}

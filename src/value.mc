// value.mc — NaN-boxed JS value in one u64.
//
// f64 numbers are raw IEEE bits. Everything else sits above the
// hardware NaN patterns (0x7FF8…, 0xFFF8…), so computed numbers never
// collide with tags. Code that injects raw f64 bits (typed arrays,
// DataView) must canonicalize NaNs before boxing.
// See doc/DESIGN_value.md.

struct GcCell;

struct Value { u64 bits; }

const u64 TAG_MASK = 0xFFFF000000000000;
const u64 TAG_INT  = 0xFFF9000000000000;
const u64 TAG_SPEC = 0xFFFA000000000000;
const u64 TAG_CELL = 0xFFFB000000000000;

const u64 PAYLOAD_MASK = 0x0000FFFFFFFFFFFF;

const u64 VAL_UNDEFINED = 0xFFFA000000000000;
const u64 VAL_NULL      = 0xFFFA000000000001;
const u64 VAL_FALSE     = 0xFFFA000000000002;
const u64 VAL_TRUE      = 0xFFFA000000000003;
const u64 VAL_HOLE      = 0xFFFA000000000004;

const u64 CANONICAL_NAN = 0x7FF8000000000000;

private unsafe_union Bits64 { f64 f; u64 u; }

Value value_number(f64 x) {
    Bits64 b;
    b.f = x;
    return Value{ b.u };
}

f64 value_as_f64(Value v) {
    Bits64 b;
    b.u = v.bits;
    return b.f;
}

Value value_int(i32 x) {
    return Value{ TAG_INT | cast(u64, cast(u32, x)) };
}

i32 value_as_int(Value v) {
    return cast(i32, v.bits);
}

Value value_bool(bool b) {
    if b { return Value{ VAL_TRUE }; }
    return Value{ VAL_FALSE };
}

Value value_undefined() { return Value{ VAL_UNDEFINED }; }
Value value_null()      { return Value{ VAL_NULL }; }
Value value_hole()      { return Value{ VAL_HOLE }; }

Value value_cell(GcCell* c) {
    return Value{ TAG_CELL | cast(u64, c) };
}

GcCell* value_as_cell(Value v) {
    return cast(GcCell*, v.bits & PAYLOAD_MASK);
}

bool value_is_double(Value v)    { return v.bits < TAG_INT; }
bool value_is_int(Value v)       { return (v.bits & TAG_MASK) == TAG_INT; }
bool value_is_number(Value v)    { return v.bits < TAG_INT || (v.bits & TAG_MASK) == TAG_INT; }
bool value_is_cell(Value v)      { return (v.bits & TAG_MASK) == TAG_CELL; }
bool value_is_undefined(Value v) { return v.bits == VAL_UNDEFINED; }
bool value_is_null(Value v)      { return v.bits == VAL_NULL; }
bool value_is_bool(Value v)      { return v.bits == VAL_TRUE || v.bits == VAL_FALSE; }
bool value_is_true(Value v)      { return v.bits == VAL_TRUE; }
bool value_is_hole(Value v)      { return v.bits == VAL_HOLE; }

bool value_same_bits(Value a, Value b) { return a.bits == b.bits; }

// The number as f64 regardless of int or double storage.
f64 value_number_f64(Value v) {
    if value_is_int(v) { return value_as_int(v); }
    return value_as_f64(v);
}

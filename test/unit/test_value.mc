// test_value.mc — NaN-boxed Value round trips and predicate disjointness.

import "../helpers/check.mc";
import "../../src/value.mc";

void check_number_roundtrip(f64 x, str what) {
    Value v = value_number(x);
    check(value_is_double(v), what);
    check(value_is_number(v), what);
    check(value_as_f64(v) == x, what);
}

i32 main() {
    // doubles
    check_number_roundtrip(0.0, "zero");
    check_number_roundtrip(3.14159, "pi-ish");
    check_number_roundtrip(-1.5, "negative");
    check_number_roundtrip(1.0e308, "large");
    check_number_roundtrip(1.0e308 * 10.0, "+inf");
    check_number_roundtrip(-1.0e308 * 10.0, "-inf");

    // -0.0 keeps its sign bit
    Value nz = value_number(-0.0);
    check(1.0 / value_as_f64(nz) < 0.0, "-0.0 preserved");

    // NaN stays a number and stays NaN
    Value nan = value_number(0.0 / 0.0);
    check(value_is_double(nan), "nan is double");
    check(value_is_number(nan), "nan is number");
    f64 back = value_as_f64(nan);
    check(back != back, "nan round trip");

    // ints
    Value i = value_int(42);
    check(value_is_int(i), "int tag");
    check(value_is_number(i), "int is number");
    check(!value_is_double(i), "int not double");
    check_eq(value_as_int(i), 42, "int round trip");
    check_eq(value_as_int(value_int(-1)), -1, "negative int");
    check_eq(value_as_int(value_int(2147483647)), 2147483647, "int max");
    check_eq(value_as_int(value_int(-2147483648)), -2147483648, "int min");
    check(value_number_f64(value_int(-7)) == -7.0, "int as f64");
    check(value_number_f64(value_number(2.5)) == 2.5, "double as f64");

    // specials are distinct and typed
    Value ud = value_undefined();
    Value nl = value_null();
    Value tr = value_bool(true);
    Value fa = value_bool(false);
    Value ho = value_hole();
    check(value_is_undefined(ud), "undefined");
    check(value_is_null(nl), "null");
    check(value_is_bool(tr) && value_is_true(tr), "true");
    check(value_is_bool(fa) && !value_is_true(fa), "false");
    check(value_is_hole(ho), "hole");
    check(!value_same_bits(ud, nl), "undefined != null");
    check(!value_same_bits(tr, fa), "true != false");
    check(!value_is_number(ud) && !value_is_cell(ud), "undefined disjoint");
    check(!value_is_bool(nl) && !value_is_hole(nl), "null disjoint");

    // cell pointers round trip
    u8* p = alloc<u8>(16);
    Value cv = value_cell(cast(GcCell*, p));
    check(value_is_cell(cv), "cell tag");
    check(!value_is_number(cv), "cell not number");
    check(cast(u8*, value_as_cell(cv)) == p, "cell round trip");
    free(p);

    return check_done("test_value");
}

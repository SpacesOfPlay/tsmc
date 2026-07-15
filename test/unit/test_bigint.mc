// test_bigint.mc — bignum core arithmetic.

import str;
import "../helpers/check.mc";
import "../../src/bigint.mc";

private void chk_str(BigNum a, str want, str label) {
    string got = bn_to_str(a);
    check(str_equal(got, want), label);
    free(got);
}

i32 main() {
    bool ok;

    BigNum a = bn_from_str("123456789012345678901234567890", &ok);
    chk_str(a, "123456789012345678901234567890", "roundtrip");
    check(ok, "roundtrip ok");

    BigNum b = bn_from_str("987654321987654321", &ok);
    BigNum sum = bn_add(a, b);
    chk_str(sum, "123456789013333333223222222211", "add");

    BigNum diff = bn_sub(a, b);
    chk_str(diff, "123456789011358024579246913569", "sub");

    BigNum prod = bn_mul(a, b);
    chk_str(prod, "121932631246761163237311385323609205901126352690", "mul");

    BigNum rem;
    BigNum q = bn_divmod(a, b, &rem, &ok);
    chk_str(q, "124999998748", "divq");
    chk_str(rem, "432099904777777782", "divr");
    check(ok, "div ok");

    // pow: 2^100
    BigNum base2 = bn_from_i64(2);
    BigNum e100 = bn_from_i64(100);
    BigNum p = bn_pow(base2, e100, &ok);
    chk_str(p, "1267650600228229401496703205376", "pow2_100");

    // negatives
    BigNum na = bn_from_str("-50", &ok);
    BigNum pb = bn_from_str("30", &ok);
    BigNum s2 = bn_add(na, pb);
    chk_str(s2, "-20", "neg_add");
    BigNum m2 = bn_mul(na, pb);
    chk_str(m2, "-1500", "neg_mul");

    // truncated division signs: -7 / 2 = -3 rem -1
    BigNum n7 = bn_from_str("-7", &ok);
    BigNum t2 = bn_from_i64(2);
    BigNum rq = bn_divmod(n7, t2, &rem, &ok);
    chk_str(rq, "-3", "tdiv_q");
    chk_str(rem, "-1", "tdiv_r");

    // compare and zero
    check(bn_cmp(a, b) == 1, "cmp_gt");
    check(bn_cmp(b, a) == -1, "cmp_lt");
    BigNum z = bn_from_i64(0);
    check(bn_is_zero(z), "zero");
    chk_str(z, "0", "zero_str");

    // division by zero flags
    BigNum dz = bn_divmod(a, z, &rem, &ok);
    check(!ok, "divzero");
    bn_free(&dz);

    return check_done("test_bigint");
}

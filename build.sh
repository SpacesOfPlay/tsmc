#!/usr/bin/env bash
# build.sh — build and test tsmc on Linux/macOS.
#
# Requires the minc compiler. MINC: minc install dir (the folder
# holding the minc binary and its lib/); defaults to the local deploy
# at ./minc (gitignored — refresh by copying in a new deploy).

set -u

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
OUT_EXE="$BUILD_DIR/tsmc"

MINC_DIR="${MINC:-$PROJECT_DIR/minc}"

# Millisecond clock. GNU date has %N (nanoseconds); BSD date on macOS
# passes the unknown %N through literally, so fall back to Perl there.
if [ "$(date +%N)" != "N" ]; then
    now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
else
    now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
fi

step() { printf '\033[36m:: %s\033[0m\n' "$1"; }
pass() { printf '\033[32m  PASS  %s\033[0m\n' "$1"; }
fail() { printf '\033[31m  FAIL  %s\033[0m\n' "$1"; }

assert_toolchain() {
    if [ ! -x "$MINC_DIR/minc" ] && [ ! -x "$MINC_DIR/minc.exe" ]; then
        fail "minc not found in $MINC_DIR"
        echo "  copy a minc deploy into minc/, or set MINC (see README.md)"
        exit 1
    fi
    MINC_DIR="$(cd "$MINC_DIR" && pwd)"
    if [ ! -f "$MINC_DIR/lib/str.mc" ]; then
        fail "no lib/ in $MINC_DIR — bare imports (import str;) cannot resolve"
        echo "  a minc install has lib/ beside the binary"
        exit 1
    fi
    PATH="$MINC_DIR:$PATH"
    export PATH
}

# Compile from the project folder; `minc` comes from PATH (install dir
# prepended above), which anchors stdlib resolution on <install>/lib.
invoke_minc() {
    (cd "$PROJECT_DIR" && minc "$@")
}

build_tsmc() {
    step "build tsmc"
    assert_toolchain
    mkdir -p "$BUILD_DIR"
    if ! invoke_minc "$PROJECT_DIR/src/main.mc" -o "$OUT_EXE"; then
        fail "compile failed"
        exit 1
    fi
    pass "$OUT_EXE"
}

run_tests() {
    build_tsmc
    n_fail=0
    n_pass=0

    # Unit tests: each test/unit/*.mc is a standalone program; exit 0 = pass.
    step "unit tests"
    mkdir -p "$BUILD_DIR/unit"
    for f in "$PROJECT_DIR"/test/unit/*.mc; do
        [ -e "$f" ] || continue
        name="$(basename "$f" .mc)"
        exe="$BUILD_DIR/unit/$name"
        if ! invoke_minc "$f" -o "$exe"; then
            fail "$name (compile)"; n_fail=$((n_fail + 1)); continue
        fi
        if ! "$exe"; then
            fail "$name (exit $?)"; n_fail=$((n_fail + 1)); continue
        fi
        pass "$name"; n_pass=$((n_pass + 1))
    done

    # CLI smoke: flag handling and exit codes.
    step "cli smoke"
    out="$("$OUT_EXE" --version)"
    if [ $? -eq 0 ] && [ "$out" = "tsmc 0.1.0-dev" ]; then
        pass "--version"; n_pass=$((n_pass + 1))
    else
        fail "--version (got '$out')"; n_fail=$((n_fail + 1))
    fi

    "$OUT_EXE" > /dev/null 2>&1
    if [ $? -eq 2 ]; then
        pass "no args exits 2"; n_pass=$((n_pass + 1))
    else
        fail "no args"; n_fail=$((n_fail + 1))
    fi

    "$OUT_EXE" "$BUILD_DIR/no_such_file.ts" 2> /dev/null
    if [ $? -eq 2 ]; then
        pass "missing file exits 2"; n_pass=$((n_pass + 1))
    else
        fail "missing file"; n_fail=$((n_fail + 1))
    fi

    # Golden run tests: run test/run/<name>.ts, diff stdout against <name>.expected.
    step "run tests"
    n_run=0
    for f in "$PROJECT_DIR"/test/run/*.ts; do
        [ -e "$f" ] || continue
        n_run=$((n_run + 1))
        name="$(basename "$f" .ts)"
        exp="${f%.ts}.expected"
        if [ ! -f "$exp" ]; then
            fail "$name (no .expected)"; n_fail=$((n_fail + 1)); continue
        fi
        actual="$("$OUT_EXE" "$f" 2> /dev/null)"
        if [ $? -ne 0 ]; then
            fail "$name (nonzero exit)"; n_fail=$((n_fail + 1)); continue
        fi
        expected="$(cat "$exp")"
        if [ "$actual" != "$expected" ]; then
            fail "$name (diff)"; n_fail=$((n_fail + 1)); continue
        fi
        pass "$name"; n_pass=$((n_pass + 1))
    done
    [ "$n_run" -eq 0 ] && echo "  (none yet)"

    echo ""
    if [ "$n_fail" -eq 0 ]; then
        pass "all $n_pass tests passed"
    else
        fail "$n_fail test(s) failed"
        exit 1
    fi
}

run_bench() {
    build_tsmc
    step "benchmarks"
    n=0
    for f in "$PROJECT_DIR"/bench/*.ts; do
        [ -e "$f" ] || continue
        n=$((n + 1))
        name="$(basename "$f" .ts)"
        start=$(now_ms)
        out="$("$OUT_EXE" "$f" 2>&1)"
        end=$(now_ms)
        ms=$(( end - start ))
        printf '  %6d ms  %-12s -> %s\n' "$ms" "$name" "$out"
    done
    [ "$n" -eq 0 ] && echo "  (none)"
}

run_diff() {
    build_tsmc
    step "differential (vs node)"
    node_bin="${NODE:-$(command -v node 2>/dev/null)}"
    if [ -z "$node_bin" ]; then echo "  skipped - node not found (set NODE)"; return; fi
    n_fail=0
    for f in "$PROJECT_DIR"/test/diff/*.js; do
        [ -e "$f" ] || continue
        name="$(basename "$f" .js)"
        if [ "$("$node_bin" "$f" 2>&1)" = "$("$OUT_EXE" "$f" 2>&1)" ]; then
            pass "$name"
        else
            fail "$name (differs from node)"; n_fail=$((n_fail + 1))
        fi
    done
    [ "$n_fail" -eq 0 ] || { fail "$n_fail differ"; exit 1; }
}

case "${1:-help}" in
    build) build_tsmc ;;
    test)  run_tests ;;
    bench) run_bench ;;
    diff)  run_diff ;;
    t262)  build_tsmc; shift; "$PROJECT_DIR/tools/test262.sh" "$@" ;;
    clean)
        step "clean"
        rm -rf "$BUILD_DIR"
        pass "removed build/"
        ;;
    *)
        echo "usage: ./build.sh <build|test|bench|diff|t262|clean>"
        echo "  build   compile build/tsmc"
        echo "  test    build, then run unit + cli + golden run tests"
        echo "  bench   build, then time bench/*.ts"
        echo "  diff    build, then diff test/diff/*.js vs node"
        echo "  t262    build, then run test262 (fetched to vendor/ on first use)"
        echo "  clean   remove build/"
        ;;
esac

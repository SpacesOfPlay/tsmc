#!/usr/bin/env bash
# test262.sh — run a subset of the official ECMAScript conformance suite
# (tc39/test262) against the built tsmc.
#
# test262 is NOT vendored into this repo. On first run it is fetched at a
# pinned commit into vendor/test262/ (gitignored), so any clone can
# reproduce the exact same tests. Set T262_COMMIT to pin a different one.
#
#   tools/test262.sh [subpath] [--limit N] [--verbose]
#
# subpath defaults to test/language (core semantics — closest to what the
# interpreter implements). Examples:
#   tools/test262.sh test/language --limit 500
#   tools/test262.sh test/built-ins/Array
#
# A test is skipped (not failed) when it needs a feature the interpreter
# does not implement (see SKIP_FEATURES) or a harness mode we do not run
# (modules, async, raw multi-realm). The honest metric is the pass rate
# over the tests that actually ran.

set -u

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$PROJECT_DIR/vendor/test262"
T262_COMMIT="${T262_COMMIT:-f2d1435644797268dca1f7988cad5a4e89ccd8d2}"

TSMC="$PROJECT_DIR/build/tsmc.exe"
[ -x "$TSMC" ] || TSMC="$PROJECT_DIR/build/tsmc"

SUBPATH="test/language"
LIMIT=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --limit=*) LIMIT="${arg#--limit=}" ;;
        --limit)   LIMIT=-1 ;;               # next positional is the number
        --verbose) VERBOSE=1 ;;
        [0-9]*)    if [ "$LIMIT" = "-1" ]; then LIMIT="$arg"; else SUBPATH="$arg"; fi ;;
        *)         SUBPATH="$arg" ;;
    esac
done

step() { printf '\033[36m:: %s\033[0m\n' "$1"; }
fail() { printf '\033[31m  %s\033[0m\n' "$1"; }

# Whole feature families the interpreter does not implement. A test tagged
# with any of these is skipped rather than counted as a failure.
SKIP_FEATURES="TypedArray ArrayBuffer SharedArrayBuffer DataView Atomics \
Proxy Reflect WeakRef FinalizationRegistry WeakMap WeakSet \
Intl decorators dynamic-import import-assertions import-attributes \
IsHTMLDDA tail-call-optimization Array.fromAsync iterator-helpers \
regexp-lookbehind regexp-unicode-property-escapes regexp-v-flag \
regexp-modifiers legacy-regexp __getter__ __setter__ __proto__ \
BigInt64Array BigInt.asIntN symbols-as-weakmap-keys \
resizable-arraybuffer explicit-resource-management \
uint8array-base64 Temporal ShadowRealm Array.prototype.at"

# Harness includes that pull in a skipped family.
SKIP_INCLUDES="testTypedArray.js detachArrayBuffer.js testBigIntTypedArray.js \
testAtomics.js atomicsHelper.js nativeFunctionMatcher.js"

if [ ! -x "$TSMC" ]; then
    fail "tsmc not built — run ./build.sh build (or build.ps1 build) first"
    exit 1
fi

# --- fetch (once) -----------------------------------------------------
if [ ! -f "$VENDOR/harness/sta.js" ]; then
    step "fetching test262 @ ${T262_COMMIT:0:12} -> vendor/test262"
    mkdir -p "$VENDOR"
    url="https://github.com/tc39/test262/archive/$T262_COMMIT.tar.gz"
    if ! curl -fsSL "$url" | tar -xz -C "$VENDOR" --strip-components=1; then
        fail "download failed ($url)"
        fail "set T262_COMMIT to a valid commit, or fetch manually into vendor/test262"
        exit 1
    fi
fi

ROOT="$VENDOR/$SUBPATH"
if [ ! -d "$ROOT" ] && [ ! -f "$ROOT" ]; then
    fail "no such path in test262: $SUBPATH"
    exit 1
fi

step "running $SUBPATH  (tsmc, pinned test262 ${T262_COMMIT:0:12})"

HBASE="$VENDOR/harness"
BASE_HARNESS="$(cat "$HBASE/sta.js" "$HBASE/assert.js")"
TMP="$(mktemp --suffix=.js)"
FAILS="$PROJECT_DIR/build/test262-fails.txt"
: > "$FAILS"
trap 'rm -f "$TMP"' EXIT

pass=0; failc=0; skip=0

# Extracts field VALUE from a test's YAML frontmatter block.
frontmatter() { sed -n '/\/\*---/,/---\*\//p' "$1"; }

run_variant() {   # <body-with-harness> <negative-phase> <negative-type>
    local src="$1" nphase="$2" ntype="$3"
    printf '%s' "$src" > "$TMP"
    local out rc
    out="$("$TSMC" "$TMP" 2>&1)"; rc=$?
    if [ -z "$nphase" ]; then
        # positive: harness throws Test262Error on failure -> nonzero exit
        [ "$rc" -eq 0 ] && return 0
        return 1
    fi
    # negative test
    if [ "$nphase" = "parse" ] || [ "$nphase" = "resolution" ] || [ "$nphase" = "early" ]; then
        [ "$rc" -eq 2 ] && return 0    # compile/parse error
        return 1
    fi
    # runtime negative: must throw, and the thrown type should match
    [ "$rc" -ne 0 ] || return 1
    case "$out" in *"$ntype"*) return 0 ;; esac
    return 1
}

run_one() {
    local f="$1"
    local fm; fm="$(frontmatter "$f")"

    local flags feats incs
    flags="$(printf '%s\n' "$fm" | sed -n 's/.*flags:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr -d ' ')"
    feats="$(printf '%s\n' "$fm" | sed -n 's/.*features:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr ',' ' ')"
    incs="$(printf '%s\n'  "$fm" | sed -n 's/.*includes:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr ',' ' ')"

    # skip: modes we do not run
    case ",$flags," in
        *,module,*|*,async,*|*,CanBlockIsFalse,*|*,CanBlockIsTrue,*)
            skip=$((skip + 1)); return ;;
    esac
    # skip: unsupported feature families
    for ft in $feats; do
        for s in $SKIP_FEATURES; do
            if [ "$ft" = "$s" ]; then skip=$((skip + 1)); return; fi
        done
    done
    # skip: harness includes we can't satisfy
    for inc in $incs; do
        for s in $SKIP_INCLUDES; do
            if [ "$inc" = "$s" ]; then skip=$((skip + 1)); return; fi
        done
    done
    # skip: dynamic code eval / Function() — out of scope, no feature tag
    if grep -qE '\b(eval|Function)[[:space:]]*\(' "$f"; then skip=$((skip + 1)); return; fi

    # negative expectation
    local nphase ntype
    nphase="$(printf '%s\n' "$fm" | sed -n 's/^[[:space:]]*phase:[[:space:]]*\([a-z]*\).*/\1/p' | head -1)"
    ntype="$(printf '%s\n'  "$fm" | sed -n 's/^[[:space:]]*type:[[:space:]]*\([A-Za-z]*\).*/\1/p' | head -1)"

    # assemble includes
    local inc_src=""
    for inc in $incs; do
        [ -f "$HBASE/$inc" ] && inc_src="$inc_src$(cat "$HBASE/$inc")"$'\n'
    done
    local body; body="$(cat "$f")"

    # which strict variants to run
    local do_strict=1 do_sloppy=1 raw=0
    case ",$flags," in
        *,raw,*)        raw=1; do_sloppy=0 ;;
        *,onlyStrict,*) do_sloppy=0 ;;
        *,noStrict,*)   do_strict=0 ;;
    esac

    local ok=1
    if [ "$raw" = "1" ]; then
        run_variant "$body" "$nphase" "$ntype" || ok=0
    else
        if [ "$do_sloppy" = "1" ]; then
            run_variant "$BASE_HARNESS"$'\n'"$inc_src$body" "$nphase" "$ntype" || ok=0
        fi
        if [ "$ok" = "1" ] && [ "$do_strict" = "1" ]; then
            run_variant '"use strict";'$'\n'"$BASE_HARNESS"$'\n'"$inc_src$body" "$nphase" "$ntype" || ok=0
        fi
    fi

    if [ "$ok" = "1" ]; then
        pass=$((pass + 1))
    else
        failc=$((failc + 1))
        echo "${f#$VENDOR/}" >> "$FAILS"
        [ "$VERBOSE" = "1" ] && fail "${f#$VENDOR/}"
    fi
}

n=0
while IFS= read -r f; do
    n=$((n + 1))
    run_one "$f"
    if [ $((n % 200)) -eq 0 ]; then printf '  %d run (%d pass, %d fail, %d skip)\r' "$n" "$pass" "$failc" "$skip"; fi
    if [ "$LIMIT" -gt 0 ] && [ "$((pass + failc))" -ge "$LIMIT" ]; then break; fi
done < <(find "$ROOT" -name '*.js' ! -name '*_FIXTURE.js' | sort)

ran=$((pass + failc))
printf '\n'
step "test262 result"
printf '  ran     %d\n' "$ran"
printf '  passed  %d' "$pass"
[ "$ran" -gt 0 ] && printf '  (%d%%)' "$((pass * 100 / ran))"
printf '\n'
printf '  failed  %d   (see build/test262-fails.txt)\n' "$failc"
printf '  skipped %d   (unsupported features/modes)\n' "$skip"

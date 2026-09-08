#!/usr/bin/env bash
# test262.sh — run a subset of the official ECMAScript conformance suite
# (tc39/test262) against the built tsmc.
#
# test262 is NOT vendored into this repo. On first run it is fetched at a
# pinned commit into vendor/test262/ (gitignored), so any clone can
# reproduce the exact same tests. Set T262_COMMIT to pin a different one.
#
#   tools/test262.sh [subpath] [--limit N] [--jobs N] [--verbose]
#
# subpath defaults to test/language (core semantics — closest to what the
# interpreter implements). Examples:
#   tools/test262.sh test/language --limit 500
#   tools/test262.sh test/built-ins/Array
#
# The tests are split into --jobs shards that run side by side; the default
# is half the cores, so the machine stays usable. --limit samples the first
# N tests and runs on one shard, so the sample is the same every time.
#
# A test is skipped (not failed) when it needs a feature the interpreter
# does not implement (see SKIP_FEATURES) or a harness mode we do not run
# (modules, raw multi-realm). The honest metric is the pass rate over the
# tests that actually ran.
#
# `flags: [async]` tests report through print(): doneprintHandle.js turns
# $DONE into one of two markers on stdout, and a test passes only if the
# completion marker shows up. Silence is a failure, which is what catches a
# promise that never settles.

set -u

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$PROJECT_DIR/vendor/test262"
T262_COMMIT="${T262_COMMIT:-f2d1435644797268dca1f7988cad5a4e89ccd8d2}"

TSMC="$PROJECT_DIR/build/tsmc.exe"
[ -x "$TSMC" ] || TSMC="$PROJECT_DIR/build/tsmc"

SUBPATH="test/language"
LIMIT=0
JOBS=0
VERBOSE=0
pending=""
for arg in "$@"; do
    case "$arg" in
        --limit=*) LIMIT="${arg#--limit=}" ;;
        --jobs=*)  JOBS="${arg#--jobs=}" ;;
        --limit)   pending=limit ;;          # next positional is the number
        --jobs)    pending=jobs ;;
        --verbose) VERBOSE=1 ;;
        [0-9]*)
            case "$pending" in
                limit) LIMIT="$arg" ;;
                jobs)  JOBS="$arg" ;;
                *)     SUBPATH="$arg" ;;
            esac
            pending="" ;;
        *)         SUBPATH="$arg" ;;
    esac
done

if [ "$JOBS" -lt 1 ]; then
    cores="$( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 2)"
    JOBS=$((cores / 2))
fi
[ "$JOBS" -lt 1 ] && JOBS=1
# A sample has to be the first N tests, which only one shard can decide.
[ "$LIMIT" -gt 0 ] && JOBS=1

step() { printf '\033[36m:: %s\033[0m\n' "$1"; }
fail() { printf '\033[31m  %s\033[0m\n' "$1"; }

# Whole feature families the interpreter does not implement. A test tagged
# with any of these is skipped rather than counted as a failure. An entry
# may end in * to cover a family and its sub-tags.
#
# Keep this list honest in both directions: a family that lands here stops
# being measured, so drop an entry as soon as the feature works.

# buffers and the shared-memory model
SKIP_FEATURES="SharedArrayBuffer Atomics* Float16Array BigInt64Array \
BigInt.asIntN resizable-arraybuffer arraybuffer-transfer \
immutable-arraybuffer uint8array-base64 \
align-detached-buffer-semantics-with-web-reality"

# host services the runner has no way to provide: a second realm, a forced
# collection, module loaders beyond plain source
SKIP_FEATURES="$SKIP_FEATURES cross-realm host-gc-required ShadowRealm \
source-phase-imports source-phase-imports-module-source import-defer \
import-attributes import-assertions import-text import-bytes json-modules"

# libraries and language extensions this runtime does not ship
SKIP_FEATURES="$SKIP_FEATURES Temporal Intl* decorators WeakRef \
FinalizationRegistry explicit-resource-management IsHTMLDDA \
tail-call-optimization"

# proposals not implemented yet
SKIP_FEATURES="$SKIP_FEATURES Array.fromAsync joint-iteration \
iterator-sequencing upsert await-dictionary Error.isError Math.sumPrecise \
promise-try json-parse-with-source RegExp.escape error-stack-accessor"

# regex features the engine does not accept
SKIP_FEATURES="$SKIP_FEATURES regexp-modifiers regexp-duplicate-named-groups \
legacy-regexp"

# protocol hooks that are not consulted: the species constructor, and the
# well-known methods String defers to
SKIP_FEATURES="$SKIP_FEATURES Symbol.species Symbol.unscopables \
Symbol.isConcatSpreadable Symbol.replace Symbol.match Symbol.split \
Symbol.search"

# Annex B leftovers we do not define
SKIP_FEATURES="$SKIP_FEATURES __getter__ __setter__ caller"

# Harness includes that pull in a skipped family, or that do not load at all
# (fnGlobalObject.js reaches the global through the Function constructor).
SKIP_INCLUDES="detachArrayBuffer.js testBigIntTypedArray.js \
testAtomics.js atomicsHelper.js fnGlobalObject.js"

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
# tsmc has no print(), which is what doneprintHandle.js reports through.
# A script's top-level declarations are not properties of the global object
# here, so $DONE is published by hand: asyncHelpers.js looks for it there
# before it will run an async test.
ASYNC_HARNESS="function print(s) { console.log(s); }
$(cat "$HBASE/doneprintHandle.js")
globalThis.\$DONE = \$DONE;"
# A test that never settles would otherwise wedge the run.
if command -v timeout >/dev/null 2>&1; then T262_RUN="timeout 10"; else T262_RUN=""; fi
# The assembled test is written beside the original, not into the system temp
# dir, so a relative specifier in an import() still finds its _FIXTURE file.
# A shard keeps one such file at a time and drops it when the directory
# changes. A killed run can leave one behind, so they are swept first and
# never picked up as tests.
find "$ROOT" -name '.t262-tmp-*.js' -delete 2>/dev/null
TMP=""
TMPDIR_SEEN=""
SHARD=0
WORK="$PROJECT_DIR/build/t262-work"
FAILS="$WORK/fails.0"
FAILS_OUT="$PROJECT_DIR/build/test262-fails.txt"
trap 'rm -f "$TMP"' EXIT

pass=0; failc=0; skip=0

# Extracts field VALUE from a test's YAML frontmatter block.
frontmatter() { sed -n '/\/\*---/,/---\*\//p' "$1"; }

run_variant() {   # <body-with-harness> <negative-phase> <negative-type> <async>
    local src="$1" nphase="$2" ntype="$3" isasync="${4:-0}"
    printf '%s' "$src" > "$TMP"
    local out rc
    out="$($T262_RUN "$TSMC" "$TMP" 2>&1)"; rc=$?
    if [ -z "$nphase" ] && [ "$isasync" = "1" ]; then
        # the markers decide, not the exit code
        case "$out" in
            *Test262:AsyncTestFailure*)  return 1 ;;
            *Test262:AsyncTestComplete*) [ "$rc" -eq 0 ] && return 0; return 1 ;;
        esac
        return 1
    fi
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
    local d="${f%/*}"
    if [ "$d" != "$TMPDIR_SEEN" ]; then
        [ -n "$TMP" ] && rm -f "$TMP"
        TMPDIR_SEEN="$d"
        TMP="$d/.t262-tmp-$SHARD.js"
    fi
    local fm; fm="$(frontmatter "$f")"

    local flags feats incs
    flags="$(printf '%s\n' "$fm" | sed -n 's/.*flags:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr -d ' ')"
    feats="$(printf '%s\n' "$fm" | sed -n 's/.*features:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr ',' ' ')"
    incs="$(printf '%s\n'  "$fm" | sed -n 's/.*includes:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr ',' ' ')"

    # skip: modes we do not run
    case ",$flags," in
        *,module,*|*,CanBlockIsFalse,*|*,CanBlockIsTrue,*)
            skip=$((skip + 1)); return ;;
    esac
    local isasync=0
    case ",$flags," in *,async,*) isasync=1 ;; esac
    # skip: unsupported feature families (entries may be globs)
    for ft in $feats; do
        for s in $SKIP_FEATURES; do
            case "$ft" in $s) skip=$((skip + 1)); return ;; esac
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
    # doneprintHandle.js is implied by the flag, not listed in includes
    [ "$isasync" = "1" ] && inc_src="$inc_src$ASYNC_HARNESS"
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
        run_variant "$body" "$nphase" "$ntype" "$isasync" || ok=0
    else
        if [ "$do_sloppy" = "1" ]; then
            run_variant "$BASE_HARNESS"$'\n'"$inc_src$body" "$nphase" "$ntype" "$isasync" || ok=0
        fi
        if [ "$ok" = "1" ] && [ "$do_strict" = "1" ]; then
            run_variant '"use strict";'$'\n'"$BASE_HARNESS"$'\n'"$inc_src$body" "$nphase" "$ntype" "$isasync" || ok=0
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

# One shard: its own counters, its own fails file, its own temp file.
# Progress is published as a line the parent adds up.
run_shard() {
    SHARD="$1"
    FAILS="$WORK/fails.$SHARD"
    : > "$FAILS"
    pass=0; failc=0; skip=0
    TMP=""; TMPDIR_SEEN=""
    local n=0
    while IFS= read -r f; do
        n=$((n + 1))
        run_one "$f"
        if [ $((n % 50)) -eq 0 ]; then publish; fi
        if [ "$LIMIT" -gt 0 ] && [ "$((pass + failc))" -ge "$LIMIT" ]; then break; fi
    done < "$WORK/list.$SHARD"
    publish
}

publish() {
    printf '%d %d %d\n' "$pass" "$failc" "$skip" > "$WORK/pending.$SHARD"
    mv -f "$WORK/pending.$SHARD" "$WORK/counts.$SHARD"
}

rm -rf "$WORK"; mkdir -p "$WORK"
find "$ROOT" -name '*.js' ! -name '*_FIXTURE.js' ! -name '.t262-tmp-*.js' | sort > "$WORK/all.txt"
total="$(wc -l < "$WORK/all.txt")"
if [ "$total" -eq 0 ]; then
    fail "no tests under $SUBPATH"
    exit 1
fi
[ "$JOBS" -gt "$total" ] && JOBS="$total"
per=$(( (total + JOBS - 1) / JOBS ))
# contiguous blocks, so a shard stays inside one directory as long as it can
awk -v per="$per" -v out="$WORK/list." '{ print > (out int((NR - 1) / per)) }' "$WORK/all.txt"

[ "$JOBS" -gt 1 ] && step "$total files, $JOBS shards"
pids=""
i=0
while [ "$i" -lt "$JOBS" ]; do
    run_shard "$i" &
    pids="$pids $!"
    i=$((i + 1))
done

alive=1
while [ "$alive" = "1" ]; do
    sleep 3
    alive=0
    for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
    cat "$WORK"/counts.* 2>/dev/null | awk \
        '{p += $1; f += $2; s += $3} END {printf "  %d run (%d pass, %d fail, %d skip)\r", p + f, p, f, s}'
done
wait

pass=0; failc=0; skip=0
for c in "$WORK"/counts.*; do
    read -r p f s < "$c"
    pass=$((pass + p)); failc=$((failc + f)); skip=$((skip + s))
done
cat "$WORK"/fails.* | sort > "$FAILS_OUT"
find "$ROOT" -name '.t262-tmp-*.js' -delete 2>/dev/null

ran=$((pass + failc))
printf '\n'
step "test262 result"
printf '  ran     %d\n' "$ran"
printf '  passed  %d' "$pass"
[ "$ran" -gt 0 ] && printf '  (%d%%)' "$((pass * 100 / ran))"
printf '\n'
printf '  failed  %d   (see build/test262-fails.txt)\n' "$failc"
printf '  skipped %d   (unsupported features/modes)\n' "$skip"

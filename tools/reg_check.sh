#!/bin/sh
# reg_check.sh <tsmc.exe> <level> [modes] [jobs] : the register form's behaviour checks
# (doc/PLAN_register_bytecode.md, "The checks every phase passes", check 1).
# Every script is run at --reg=0 and at --reg=<level> by the same binary and
# the outputs, exit status included, compared: plainly, under --gc-stress,
# with every compile round-tripped through the code cache, with every lazy
# function compiled ahead, and under --gc-stress with each temporary
# overwritten as it is released (--reg-clear). The scripts run `jobs` at a
# time (default half the cores). A script that does not finish within 30 s
# at level 0 (a server example) is counted apart and not compared. Prints
# one line per mode and each script that differs.
exe=$1; level=$2
only=${3:-plain,gc-stress,cache-verify,cache-ahead,cleared}
jobs=${4:-$(( $(nproc) / 2 ))}
cd "$(dirname "$0")/.."
goldens=$(ls test/run/*.ts test/diff/*.js test/diff/*.ts 2>/dev/null)
all="$goldens $(find bench examples test/unit test/cli test/neg -name '*.js' -o -name '*.ts' 2>/dev/null | grep -v node_modules)"
out=$(mktemp -d)

# check <mode> <scripts> <flags...>
check() {
    mode=$1; set_=$2; shift 2
    printf '%s\n' $set_ | xargs -P "$jobs" -I{} sh -c '
        exe=$0; level=$1; f=$2; shift 2
        a=$(timeout 30 "$exe" "$@" --reg=0 "$f" 2>&1; echo "exit $?")
        case "$a" in *"exit 124") echo "SLOW $f"; exit 0 ;; esac
        b=$(timeout 60 "$exe" "$@" --reg=$level "$f" 2>&1; echo "exit $?")
        if [ "$a" = "$b" ]; then echo "SAME $f"; else echo "DIFF $f"; fi
    ' "$exe" "$level" {} "$@" > "$out/$mode.txt"
    n=$(wc -l < "$out/$mode.txt"); d=$(grep -c '^DIFF' "$out/$mode.txt"); s=$(grep -c '^SLOW' "$out/$mode.txt")
    grep '^DIFF' "$out/$mode.txt" | sed "s/^/  ($mode) /"
    echo "$mode: $n scripts, $d differ, $s not finishing at level 0"
}
case ",$only," in *,plain,*) check plain "$all" ;; esac
# the stress modes over the goldens, as the suite's own gc-stress step
case ",$only," in *,gc-stress,*) check gc-stress "$goldens" --gc-stress ;; esac
case ",$only," in *,cache-verify,*) check cache-verify "$all" --code-cache-verify ;; esac
case ",$only," in *,cache-ahead,*) check cache-ahead "$all" --lazy --code-cache-ahead ;; esac
case ",$only," in *,cleared,*) check cleared "$goldens" --gc-stress --reg-clear ;; esac
rm -rf "$out"

#!/bin/sh
# reg_check.sh <tsmc.exe> <level> [modes] : the register form's behaviour checks
# (doc/PLAN_register_bytecode.md, "The checks every phase passes", check 1).
# Every script is run at --reg=0 and at --reg=<level> by the same binary and
# the outputs compared, plainly, under --gc-stress, with every compile
# round-tripped through the code cache, and with every lazy function compiled
# ahead, and under --gc-stress with each temporary overwritten as it is
# released (--reg-clear). Prints one line per mode and each script that differs.
exe=$1; level=$2
cd "$(dirname "$0")/.."
goldens=$(ls test/run/*.ts test/diff/*.js test/diff/*.ts 2>/dev/null)
all="$goldens $(find bench examples test/unit test/cli test/neg -name '*.js' -o -name '*.ts' 2>/dev/null | grep -v node_modules)"
# check <mode> <scripts> <flags...>
check() {
    mode=$1; set_=$2; shift 2
    n=0; d=0
    for f in $set_; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        a=$(timeout 120 "$exe" "$@" --reg=0 "$f" 2>&1 | head -c 50000)
        b=$(timeout 120 "$exe" "$@" --reg=$level "$f" 2>&1 | head -c 50000)
        if [ "$a" != "$b" ]; then d=$((d + 1)); echo "  DIFF ($mode) $f"; fi
    done
    echo "$mode: $n scripts, $d differ"
}
only=${3:-plain,gc-stress,cache-verify,cache-ahead,cleared}
case ",$only," in *,plain,*) check plain "$all" ;; esac
# the stress modes over the goldens, as the suite's own gc-stress step
case ",$only," in *,gc-stress,*) check gc-stress "$goldens" --gc-stress ;; esac
case ",$only," in *,cache-verify,*) check cache-verify "$all" --code-cache-verify ;; esac
case ",$only," in *,cache-ahead,*) check cache-ahead "$all" --lazy --code-cache-ahead ;; esac
case ",$only," in *,cleared,*) check cleared "$goldens" --gc-stress --reg-clear ;; esac

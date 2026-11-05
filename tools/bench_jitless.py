"""The interpreter against V8's: every bench/*.js and bench/micro/*.js
timed under tsmc and under node --jitless (Ignition alone, the nearer
comparison for an interpreter) and under node, the least of three, each
engine's startup floor (build/bench-empty.js) taken out.

    python tools/bench_jitless.py [--tsmc exe]

The micro scripts are one loop of 20 million iterations each: loop.js
the loop alone, and call.js, prop.js and method.js one call, one read of
the tenth key of an object, one method call on top of it; their cost
per iteration is the difference from loop.js.
"""
import os, subprocess, sys, time

T = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tsmc = os.path.join(T, "build", "tsmc.exe")
if "--tsmc" in sys.argv: tsmc = sys.argv[sys.argv.index("--tsmc") + 1]

def best_ms(cmd, n=3):
    best = 1e9
    for _ in range(n):
        a = time.perf_counter()
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        best = min(best, time.perf_counter() - a)
    return best * 1000

empty = os.path.join(T, "build", "bench-empty.js")
floors = (best_ms([tsmc, empty], 5), best_ms(["node", "--jitless", empty], 5), best_ms(["node", empty], 5))
print("floors: tsmc %.0f ms, node --jitless %.0f, node %.0f" % floors)
print("%-14s %8s %10s %8s %8s %8s" % ("bench", "tsmc", "jitless", "node", "ts/jl", "ts/node"))
def row(name, path):
    a = best_ms([tsmc, path]) - floors[0]
    c = best_ms(["node", "--jitless", path]) - floors[1]
    d = best_ms(["node", path]) - floors[2]
    print("%-14s %8.0f %10.0f %8.0f %8.2f %8.2f" % (name, a, c, d, a / c if c > 5 else 0, a / d if d > 5 else 0))
    return a, c
for b in sorted(os.listdir(os.path.join(T, "bench"))):
    if b.endswith(".js"): row(b[:-3], os.path.join(T, "bench", b))
micro = os.path.join(T, "bench", "micro")
base = row("micro/loop", os.path.join(micro, "loop.js"))
print("  %.1f vs %.1f ns an iteration" % (base[0] / 20, base[1] / 20))
for b in ("call", "prop", "method"):
    r = row("micro/" + b, os.path.join(micro, b + ".js"))
    print("  on top of the loop: %.1f vs %.1f ns" % ((r[0] - base[0]) / 20, (r[1] - base[1]) / 20))

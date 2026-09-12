# Benchmarks

Timing workloads for tracking interpreter performance, and for comparing it
with a reference node. Run with `minc bench`: each `bench/*.js` is timed
under both engines and the ratio of the work printed, with each engine's own
startup floor taken out. `BASELINE.md` holds the last measured table and the
method in full.

Not a CI gate; a tool for spotting regressions and measuring optimizations.
Each script is plain JavaScript so both engines run the same file, must exit 0
and must print a deterministic result — the runner compares the two outputs,
so a benchmark that drifts apart is measuring different work and is reported
as such (they double as smoke tests).

Sizes are chosen so node does tens of milliseconds of real work above its own
floor. Keep them fixed unless the numbers stop being informative, so runs
stay comparable.

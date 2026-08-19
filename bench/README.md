# Benchmarks

Timing workloads for tracking interpreter performance. Run with
`minc bench` —
each script is timed with the built `tsmc` and its output printed.

Not a CI gate; a tool for spotting regressions and measuring
optimizations. Each script must exit 0 and print a deterministic
result (they double as smoke tests).

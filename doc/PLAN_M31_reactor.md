# PLAN M31 — the event-loop reactor

Stage 1 of `doc/DESIGN_networking.md`. Converts the virtual-time event
loop into a real, wait-capable reactor with an I/O handle table and
Node-style ref-counting — **without adding any JS-visible API**. This is
the foundation the `net`/`http`/TLS stages build on, so it lands on its
own with the existing async surface unchanged.

## Why first

`vm_run_event_loop` (src/vm.mc) today drains microtasks, fires the
earliest timer *immediately* (virtual time, no sleeping), and exits when
jobs and timers are both empty. A socket can't be virtualized — you have
to wait on the OS for bytes — so before any networking lands the loop has
to learn to (a) wait against a real clock and (b) stay alive for reasons
other than a pending timer. Doing this as its own milestone keeps the
risky loop surgery isolated and fully covered by the current
async/timer/promise tests before new I/O rides on top.

## In scope

- Real-clock timer scheduling: the loop sleeps until the nearest timer is
  due instead of firing instantly. `setTimeout(fn, 1000)` waits ~1 s of
  wall-clock time.
- An **I/O handle table** (`vm.handles`) and ref-count that governs
  process liveness — the reactor stays alive while any ref'd handle
  exists, matching Node's ref/unref. Dormant in M31 (nothing registers a
  handle yet) but fully wired, GC-marked, and unit-tested.
- Loop exit condition generalized from "no timers" to "no jobs AND no
  alive timers AND no ref'd handles".
- A monotonic wait primitive (`Sleep` on Windows) plus reuse of the
  existing `os_mono_ns` clock.

## Out of scope (later stages)

- `WSAPoll` and any real fd readiness — arrives in M32 with the first
  socket, where it can actually be exercised. M31 waits via `Sleep`
  because there is nothing to poll yet.
- Sockets, DNS, `net`/`http`/`fetch`, TLS — M32+.
- Non-blocking mode, backpressure, the data path — M32+.

## Design

### Handle table

```
struct IoHandle {
    i64   fd;         // OS socket; -1 while unused in M31
    i32   kind;       // listener / connecting / connected (M32+)
    i32   interest;   // readable/writable mask for WSAPoll (M32+)
    bool  reffed;     // does this keep the loop alive?
    bool  alive;      // false once closed; compacted lazily
    Value owner;      // JS Socket/Server object; GC-marked, dispatch target
}
```

`vm.handles: Vec<IoHandle>` with `vm_handle_add` / `vm_handle_close` /
`vm_handle_ref` / `vm_handle_unref`. GC marks `owner` for every alive
handle (new case in `js_trace`/the VM mark pass, beside the timer/job
marks). In M31 only the ref-count fields are used; the fd/kind/interest
fields are declared so M32 fills them without touching the loop again.

`vm_handles_alive()` → true if any `alive && reffed` handle exists.

### The loop

```
i32 vm_run_event_loop(vm):
    while true:
        drain jobs                        # unchanged microtask/reaction pump
        if a timer is due now: fire earliest, continue
        # nothing runnable right now — decide whether to wait or stop
        deadline = earliest alive timer due, or NONE
        if deadline == NONE and not vm_handles_alive(): break
        wait = deadline == NONE ? INFINITE : max(0, deadline - os_mono_ns())
        os_wait(wait)                      # M31: Sleep(ms).  M32: WSAPoll(handles, ms)
    compact handles; return status
```

Microtask/reaction draining and the uncaught-exception handling are
lifted verbatim from the current loop — only the "pick and fire a timer"
tail changes from *always fire the earliest* to *fire only if due, else
wait to the deadline*.

### Real-time semantics

The one observable behavior change: timer callbacks now run at their real
due time rather than immediately in delay order. Relative ordering is
unchanged, so program *output* is unchanged; the suite just spends real
wall-clock time on any non-zero delay. Guard rails:

- Audit `test/run/*` and `test/diff/*` for large delays; anything on the
  order of seconds gets trimmed so the gated suite stays fast. (Ordering,
  not duration, is what those tests assert.)
- Windows `Sleep` granularity is ~15 ms; sub-tick delays round up. Node
  has the same coarseness, so ordering-based tests are unaffected; note
  it so nobody chases a "timer fired 14 ms late" ghost.

## Testing

- **Regression baseline:** every existing async / timer / promise / TLA
  test (`test_async`, `test/run/async`, `tla`, the promises/events diff
  tests) must stay byte-identical. This is the primary safety net for the
  loop rewrite.
- **New unit test** (`test_reactor` or extend `test_vm`): register a
  dummy `IoHandle`, assert the loop *does not* exit while it is
  `reffed`+`alive`, exits once `unref`'d or closed, and that a queued
  timer still fires alongside a live handle. Exercises the new exit
  condition and ref-count without needing a socket.
- **Timing sanity (non-gated):** a manual check that `setTimeout(_, 200)`
  actually consumes ~200 ms of wall-clock — kept out of the gated suite
  (timing is machine-dependent).
- Full suite green under `--gc-stress`, including a stress pass over a
  script that opens/holds/drops dummy handles to shake out the new GC
  rooting.

## Risks

- **Ordering regressions.** The rewrite must preserve microtask-then-
  timer ordering exactly. Mitigation: reuse the existing drain code
  unchanged; lean on the byte-identical async baseline.
- **Suite wall-clock cost.** Real timers make delay-heavy tests slower;
  mitigated by the delay audit above.
- **Idle busy-loop.** If the wait primitive is skipped when a handle is
  live but not ready, the loop spins. M31 has no not-ready handles, but
  the `os_wait` path is written so M32's WSAPoll slots in without
  reintroducing a spin.

## Deliverable

`vm_run_event_loop` rewritten as above; `IoHandle` + `vm.handles` +
ref-count API + GC marking; a `Sleep`-based `os_wait`; a reactor unit
test; delay audit applied; full suite + `--gc-stress` green. No new
globals, modules, or JS-visible behavior beyond real-time timers.

## Shipped

- **`vm_run_event_loop`** now fires the earliest timer only when it is
  due and otherwise sleeps on the monotonic clock until its deadline;
  exit is governed by `jobs || alive timers || ref'd handles`.
  `VmTimer.due` became an absolute millisecond deadline (`vm_add_timer`
  stamps `now + delay`).
- **`IoHandle` + `vm.handles`** with `vm_handle_add/close/ref/unref` and
  `vm_handles_alive`, GC-marked via each live handle's `owner`. Dormant
  (nothing registers a handle yet); `test/unit/test_reactor.mc` covers
  the ref-count logic and that the loop terminates once a handle closes.
- **`src/os_time.mc`** (new): `vm_clock_ns` + `vm_wait_ms`. Placed below
  the builtins layer — not in builtins — so `vm.mc` and its standalone
  unit tests can use them without importing builtins (which imports
  `vm`). Windows uses `Sleep`; POSIX uses `nanosleep`.
- **Verification:** full suite green (51 tests, +`test_reactor`),
  `--gc-stress` clean, and the differential harness byte-identical to
  Node (notably `promises`/`events`/`fs_async`/`coremodules`). A manual
  timing check confirmed `setTimeout`/`await sleep(n)` now consume real
  wall-clock time. Largest suite delay is 20 ms, so no trimming was
  needed and the gated run stays ~6 s.

Deviation from plan: the wait primitive lives in the new `os_time.mc`
module rather than inside the loop file, for the import-layering reason
above. `WSAPoll` remains deferred to M32 as planned — M31 waits via
`Sleep`, since there are no fds to poll yet.

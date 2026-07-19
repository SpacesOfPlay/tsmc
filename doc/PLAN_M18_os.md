# M18 — `os` module

Rounds out the fs/path/os trio for real CLI scripts. Same built-in ES
module delivery as M17 (`import os from 'os'` / `'node:os'`).

## Shipped

- **Compile-time**: `platform()` (`win32`/`linux`/`darwin`), `arch()`
  (`x64`/`arm64`), `type()` (`Windows_NT`/`Linux`/`Darwin`), `EOL`
  (`\r\n`/`\n`), `endianness()` (`LE` — all targets are little-endian).
- **Environment/OS**: `homedir()` (`USERPROFILE` / `HOME`), `tmpdir()`
  (`TEMP`/`TMP` / `TMPDIR`, trailing separator trimmed, platform
  fallback), `hostname()` (`GetComputerNameA` / `gethostname`).
- **`cpus()`** — an array of length = logical CPU count
  (`GetSystemInfo` / `sysconf(_SC_NPROCESSORS_ONLN)`), each entry a
  `{ model, speed, times:{user,nice,sys,idle,irq} }` with placeholder
  model/speed/times (the count is the real, commonly-used value).
- **`userInfo()`** — `{ username, homedir, uid, gid, shell }` from the
  environment (uid/gid = -1 on Windows).

Golden-tested for shape/invariants (values are host-varying), gc-stressed.

## Not doing (documented)

- **`totalmem()` / `freemem()` / `uptime()` / `loadavg()`** — live system
  metrics; each is a separate platform call, deferred until needed.
- **`networkInterfaces()`**, `os.constants`, `os.getPriority` — larger
  surfaces, out of scope.
- **Per-core `cpus()` model/speed/times** — real values need
  `/proc/cpuinfo` / registry / `sysctl`; the array length is real, the
  per-entry fields are placeholders.

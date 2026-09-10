# M47 — releases

Status: the flow exists and produces verified archives locally; no
version has been tagged yet, so the workflow has not run on GitHub.

## Why

Until now the only way to get tsmc was to install a compiler and build
it. The interpreter is a single self-contained executable, which is most
of what a release needs; what was missing was a way to hand someone the
file.

## What a release is

One archive per platform, plus a checksum list, published as the assets
of a GitHub release:

| archive | platform |
|---|---|
| `tsmc-<version>-windows-x64.zip` | Windows, x86-64 |
| `tsmc-<version>-linux-x64.zip` | Linux, x86-64 |
| `tsmc-<version>-linux-arm64.zip` | Linux, ARM64 |
| `tsmc-<version>-macos-arm64.zip` | macOS, Apple silicon |
| `tsmc-<version>-wasm.zip` | the wasm module, its host glue, the node runner |
| `SHA256SUMS` | one line per archive, in `sha256sum -c` format |

Each archive holds a directory named after itself, so unpacking never
litters, and inside it the binary under a plain name (`tsmc` or
`tsmc.exe`), `LICENSE.md`, `NOTICE.md` and the readme from `dist/`.
Compression pays for itself: a 2.2 MB binary ships as an 838 KB zip.

The archive is also where the notices live, which a bare binary had
nowhere to carry. The binary has picotls (MIT), cifra (CC0), monocypher
and the 119-certificate Mozilla root store from curl's `cacert.pem`
(MPL-2.0) compiled into it, and both MIT and the MPL attach their notice
requirement to distribution in binary form. `NOTICE.md` reproduces them.

The wasm module is not an executable, so it travels with the host that
gives it a file view, a clock, output and randomness, and with the node
runner the test suite uses. `tools/wasm_run.js` reads the host from
`web/` beside it, so both keep their repository paths inside the archive
and `node tools/wasm_run.js tsmc.wasm script.ts` works from the unpacked
directory.

## What the binary needs

Nothing but the platform it runs on, which is what makes a single file a
plausible download:

| platform | links against |
|---|---|
| Windows | kernel32, ucrtbase, ws2_32, advapi32, bcrypt, shell32, winmm, msvcrt — 63 symbols, all of them Windows' own |
| Linux | `libc.so.6` and the loader, with no symbol versioning, so it is not pinned to a glibc release |
| macOS | `/usr/lib/libSystem.B.dylib` and `dyld`, ad-hoc signed by the compiler, which is what lets an ARM64 binary execute at all |

Everything else is compiled in: the Unicode 16.0 property tables, the
regex engine, the TLS 1.3 stack and its root store. The interpreter reads
exactly one file it was not given on the command line: none. A glibc
system is assumed, so Alpine needs `gcompat` or a build from source, and
macOS on Intel is not published because the compiler's macOS target is
ARM64.

## Where the version lives

`src/version.mc` holds `TSMC_VERSION`, and it is the only place the
number is written. The interpreter prints it for `--version`, the CLI
smoke test compares that line against it, and the release verb names its
archives with it. Between releases it carries a `-dev` suffix, which the
workflow refuses to publish.

Three links have to agree, and each is checked where it is cheapest:

- the tag against `src/version.mc` — the workflow, before it builds
  anything, so a mistyped tag costs seconds;
- `src/version.mc` against the built binary — the release verb runs the
  binary it just built for its own host and compares `--version`;
- the binary against what is published — the workflow publishes exactly
  the directory the verb wrote.

## The verb

```
minc build.mc -o build/build.exe
build/build.exe release
```

`run_release` in `build.mc` cross-compiles `src/main.mc` once per target
into `build/stage/`, packs each with the licence, the notices and the
readme, hashes the archives, and writes `SHA256SUMS`. Every target is
cross-compiled, including the host's, so any machine produces the whole
set; the run takes about ten seconds on the development machine. Release
binaries are built with the same flags as every other build, bounds
checks included. The archives are byte-identical between runs: the zip
writer stamps a fixed timestamp.

## The workflow

`.github/workflows/release.yml` runs on a `v*` tag: install minc, check
the tag against `src/version.mc`, run `minc test`, run the release verb,
then `gh release create` with the whole directory and generated notes.
It uses the `gh` CLI the runner already has, so the release path depends
on no third-party action.

A `workflow_dispatch` run does everything except publish, and attaches
the archives to the run instead. That is the way to exercise the flow
without cutting a release.

## Cutting a release

1. Set `TSMC_VERSION` in `src/version.mc` to the version, without the
   `-dev` suffix. Commit it.
2. `git tag v<version> && git push origin v<version>`.
3. Watch the run. It publishes the release, or it fails before building
   if the tag and the source disagree.
4. Set `TSMC_VERSION` back to the next `-dev` version and commit.

## Not covered

- The archives carry no Unix permission bit, so `chmod +x` is still the
  first step on macOS and Linux; `dist/README.md` says so. A tar.gz
  would carry the mode, at the cost of a second archive format.
- No code signing on Windows, and only an ad-hoc signature on macOS, so
  both warn about an unknown developer. Real signing needs certificates
  the project does not have.
- No installer, no `curl | sh`, no package manager entries. The release
  page is the whole distribution channel.
- No examples in the archive. The playground examples live inside
  `web/index.html` rather than as files, and `examples/` holds two
  projects, one with 2.3 MB of vendored `node_modules`, so shipping
  examples means curating and testing a small set first.
- Only the host's binary is run during a release; the other three are
  produced but never executed on their platforms.
- Nothing runs `minc test` on an ordinary push. The release gate is the
  only place CI runs the suite.
- CI installs the current minc release and does not pin it, so the tree
  has to build with what is published. Checked on 0.9.14: build, the
  full suite and the release verb all pass.

# M47 — releases

Status: the flow exists and produces verified artifacts locally; no
version has been tagged yet, so the workflow has not run on GitHub.

## Why

Until now the only way to get tsmc was to install a compiler and build
it. The interpreter is a single self-contained executable with nothing
to install beside it, which is most of what a release needs; what was
missing was a way to hand someone the file.

## What a release is

Five files and a checksum list, published as the assets of a GitHub
release:

| file | platform |
|---|---|
| `tsmc-<version>-windows-x64.exe` | Windows, x86-64 |
| `tsmc-<version>-linux-x64` | Linux, x86-64 |
| `tsmc-<version>-linux-arm64` | Linux, ARM64 |
| `tsmc-<version>-macos-arm64` | macOS, Apple silicon |
| `tsmc-<version>.wasm` | the browser module |
| `SHA256SUMS` | one line per file, in `sha256sum -c` format |

They are bare files rather than archives. A download is then the thing
that runs, the checksum covers the bytes that run, and there is no
unpacking step; the cost is that macOS and Linux users set the execute
bit themselves, which the README says. Archives would only pay for
themselves if a package manager or an installer script needed them.

macOS on Intel is absent because the compiler's macOS target is ARM64.
Nothing is code-signed or notarized, so macOS quarantines a downloaded
binary until `xattr -d com.apple.quarantine` clears it.

## Where the version lives

`src/version.mc` holds `TSMC_VERSION`, and it is the only place the
number is written. The interpreter prints it for `--version`, the CLI
smoke test compares that line against it, and the release verb names its
artifacts with it. Between releases it carries a `-dev` suffix, which no
tag can match.

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
into `build/release/`, hashes each file it wrote, and writes
`SHA256SUMS`. Every target is cross-compiled, including the host's, so
any machine produces the whole set: the run above takes about seven
seconds on the development machine. Release binaries are built with the
same flags as every other build, bounds checks included.

## The workflow

`.github/workflows/release.yml` runs on a `v*` tag: install minc, check
the tag against `src/version.mc`, run `minc test`, run the release verb,
then `gh release create` with the whole directory and generated notes.
It uses the `gh` CLI that the runner already has, so the release path
depends on no third-party action.

A `workflow_dispatch` run does everything except publish, and attaches
the binaries to the run instead. That is the way to exercise the flow
without cutting a release.

## Cutting a release

1. Set `TSMC_VERSION` in `src/version.mc` to the version, without the
   `-dev` suffix. Commit it.
2. `git tag v<version> && git push origin v<version>`.
3. Watch the run. It publishes the release, or it fails before building
   if the tag and the source disagree.
4. Set `TSMC_VERSION` back to the next `-dev` version and commit.

## Not covered

- No code signing on Windows or macOS, so both warn about an unknown
  publisher. Signing needs certificates the project does not have.
- No installer or `curl | sh` script, and no package manager entries.
  The release page is the whole distribution channel.
- Only the host's binary is run during a release; the other three are
  produced but never executed on their platforms. The wasm module is
  covered by `minc test`, which cross-compiles and runs the golden tests
  through it.
- Nothing runs `minc test` on an ordinary push. The release gate is the
  only place CI runs the suite.

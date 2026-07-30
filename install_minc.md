# Installing minc

[minc](https://minc.dev) is a minimal language for building native
software. The code in this repo compiles with the minc toolchain.

One-line install:

```
# Windows
powershell -c "irm minc.dev/install.ps1 | iex"

# macOS / Linux
curl -fsSL https://minc.dev/install | bash
```

Or run the scripts checked into this repo — they fetch the same
installer, and pin the compiler version this repo was tested with
when one is set:

```
./install_minc.sh                                          # macOS / Linux
powershell -ExecutionPolicy Bypass -File install_minc.ps1  # Windows
```

The installer puts the toolchain in `~/.minc` (override with
`MINC_INSTALL`), adds it to your PATH, and offers to install the
VS Code extension if VS Code is present.

Update any time with the script installed next to the compiler:

```
~/.minc/minc_update.sh                  # macOS / Linux
%USERPROFILE%\.minc\minc_update.cmd     # Windows
```

- Samples: https://github.com/SpacesOfPlay/minc-samples
- Docs: https://minc.dev/docs/

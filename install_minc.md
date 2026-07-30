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

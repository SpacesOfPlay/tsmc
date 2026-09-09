# tsmc

A TypeScript runtime. `tsmc script.ts` parses the type annotations,
erases them, lowers the TypeScript constructs that have runtime meaning,
and runs the result on a bytecode interpreter with a precise mark-sweep
garbage collector. `.js` files run too, and both `require` and `import`
walk `node_modules`.

This archive holds one binary and nothing that has to be installed. Put
it wherever you keep such things, or on your PATH.

## Running it

Windows:

```
tsmc.exe script.ts
```

Linux:

```
chmod +x tsmc
./tsmc script.ts
```

macOS, where a binary that arrived from a browser is quarantined until
you clear the flag:

```
chmod +x tsmc
xattr -d com.apple.quarantine tsmc
./tsmc script.ts
```

`tsmc --version` prints the version, and `--gc-stress` collects on every
allocation, which is how the test suite hunts for a missing GC root.

## The wasm archive

The `-wasm` archive holds the module rather than an executable, plus the
host glue it needs: a file view, a clock, console output and a random
source. Under node, from the directory this file is in:

```
node tools/wasm_run.js tsmc.wasm script.ts
```

`web/tsmc_host.js` is the same host, for a page. The sandbox has no
sockets, no writes and no environment.

## Where things are

- The source, the documentation and the issue tracker:
  <https://github.com/SpacesOfPlay/tsmc>
- A page that runs TypeScript in the browser through the wasm build:
  <https://spacesofplay.github.io/tsmc/>
- What is implemented, what is not, and which npm packages have been
  tried: the repository's `README.md` and `doc/npm-compatibility.md`.

`LICENSE.md` is the licence, MIT. `NOTICE.md` carries the notices of the
third-party code compiled into the binary.

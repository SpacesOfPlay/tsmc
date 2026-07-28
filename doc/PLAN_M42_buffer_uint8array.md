# M42 — Buffer as a real Uint8Array

## Why

`Buffer` is currently a JS **array** whose prototype chain runs to
`Array.prototype`. Every element is a boxed number in the object's element
storage. Node's `Buffer` is a `Uint8Array` subclass over an `ArrayBuffer`.

The differential sweep (`test/diff/buffer_semantics.js`) found 29 divergences.
Twenty were fixable against the array backing and are fixed. The remaining
**nine all follow from the backing alone**:

| behaviour | node | tsmc today |
|---|---|---|
| `b instanceof Uint8Array` | `true` | `false` |
| `ArrayBuffer.isView(b)` | `true` | `false` |
| `toString.call(b)` | `[object Uint8Array]` | `[object Array]` |
| `b[0] = 300` | `44` (truncated) | `300` |
| `b.slice(1,3)` | shares memory | copies |
| `b.subarray(2)` | shares memory | copies |
| `b.buffer` / `byteOffset` / `byteLength` | present | absent |
| `Buffer.from(arrayBuffer)` | shares memory | `TypeError` |
| `readBigUInt64BE` etc. | works | absent |

These are not cosmetic. A package that hands a Buffer to a function typed
against `Uint8Array`, or that slices a buffer expecting a view rather than a
copy, gets the wrong answer with no error. `.buffer`/`.byteOffset` are the
normal way to reach the underlying bytes.

## Shape of the change

1. **Backing.** `buf_new` allocates a `Uint8Array` (the existing typed-array
   representation: `OBJF_TYPEDARRAY` plus the `%talen`/`%taoff`/buffer slots)
   with `vm.buffer_proto` as its prototype, and `vm.buffer_proto`'s own
   prototype becomes the `Uint8Array` prototype rather than `Array.prototype`.
2. **Accessors.** `buf_byte` and every `js_array_set(b, i, ...)` in the Buffer
   natives move to `vm_ta_get`/`vm_ta_set`. There are ~26 such sites, all in
   `builtins.mc`.
3. **`is_buffer`** currently tests `OBJF_ARRAY && proto == buffer_proto`; it
   becomes a typed-array test with the same prototype check.
4. **`slice`/`subarray`** return a view over the same ArrayBuffer instead of a
   copy — the typed-array code already has this; Buffer's own override goes
   away or delegates.
5. **`Buffer.from(arrayBuffer[, off[, len]])`** becomes a view rather than a
   rejection.
6. **BigInt accessors** need 64-bit element reads; they can be built on the
   byte helpers added in this round rather than waiting for
   `BigInt64Array`.

## What it will break

`Buffer` is the currency of `fs`, `http`, `tls`, `crypto`, `zlib` and
`stream`. Anything that checks `value_is_array` on a buffer, or reads it with
`js_array_get`, stops working. Known sites: the stream implementation checks
`value_is_array(bufv)` on its `%buf` slot in three places. **Grep for
`value_is_array` and `js_array_get` across every consumer before starting**,
not only in the Buffer natives.

`TextEncoder` currently returns a Buffer with a comment saying there is no
Uint8Array; that comment is stale and the return type should be revisited at
the same time (node's `TextEncoder.encode` returns a `Uint8Array`, not a
Buffer).

## Checking it

`test/diff/buffer_semantics.js` already encodes the target behaviour for the
twenty fixed items; the nine listed above are removed from it and listed in
its header. Re-add them as the conversion lands — they are the acceptance
criteria. `--gc-stress` matters here: the element storage changes shape, so
run the full stress pass rather than the diff suite alone.

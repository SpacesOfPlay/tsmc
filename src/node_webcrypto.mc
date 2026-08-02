// node_webcrypto.mc -- the `crypto` global (Web Crypto), over the node crypto
// module's primitives.
//
// randomUUID and getRandomValues are what most code reaches for; subtle
// carries digest and nothing else, since the key-handling half of SubtleCrypto
// is a much larger piece of work and a stub that answered `function` to a
// feature check would be worse than an absent one.
//
// Embedded JS: no backslash escapes (minc processes them in string literals)
// and no double quotes.

str node_webcrypto_source() {
    return "'use strict';

const nodeCrypto = require('crypto');
const DOMException = require('_webevents').DOMException;

const DIGESTS = Object.assign(Object.create(null), {
  'SHA-1': 'sha1', 'SHA-256': 'sha256', 'SHA-384': 'sha384', 'SHA-512': 'sha512',
});

// Anything the platform hands out bytes for: a view over a buffer, but not a
// float one, since a random bit pattern is not a meaningful float.
function integerView(v) {
  if (v === null || typeof v !== 'object') return false;
  if (typeof v.byteLength !== 'number' || typeof v.byteOffset !== 'number') return false;
  if (!(v.buffer instanceof ArrayBuffer)) return false;
  if (v instanceof Float32Array || v instanceof Float64Array) return false;
  if (typeof DataView === 'function' && v instanceof DataView) return false;
  return true;
}

function bytesOf(data) {
  if (data instanceof ArrayBuffer) return Buffer.from(new Uint8Array(data));
  if (data && typeof data.byteLength === 'number' && data.buffer instanceof ArrayBuffer) {
    return Buffer.from(new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
  }
  if (Buffer.isBuffer(data)) return data;
  return null;
}

class Crypto {
  randomUUID() { return nodeCrypto.randomUUID(); }

  getRandomValues(view) {
    if (arguments.length === 0) {
      throw new TypeError('The argument must be an integer-typed TypedArray');
    }
    if (!integerView(view)) {
      throw new DOMException('The provided ArrayBufferView is not an integer-typed array',
        'TypeMismatchError');
    }
    if (view.byteLength > 65536) {
      throw new DOMException('The ArrayBufferView byte length exceeds 65536',
        'QuotaExceededError');
    }
    if (view.byteLength === 0) return view;
    const bytes = nodeCrypto.randomBytes(view.byteLength);
    const dv = new DataView(view.buffer, view.byteOffset, view.byteLength);
    for (let i = 0; i < view.byteLength; i++) dv.setUint8(i, bytes[i]);
    return view;
  }

  get subtle() { return subtle; }
}
Object.defineProperty(Crypto.prototype, Symbol.toStringTag, { value: 'Crypto', configurable: true });

class SubtleCrypto {
  // Named the way the platform names them, not the way node's module does.
  digest(algorithm, data) {
    return new Promise(function (resolve, reject) {
      const name = typeof algorithm === 'string' ? algorithm : (algorithm && algorithm.name);
      const which = DIGESTS[String(name).toUpperCase()];
      if (!which) {
        reject(new DOMException('Unrecognized algorithm name', 'NotSupportedError'));
        return;
      }
      const bytes = bytesOf(data);
      if (bytes === null) {
        reject(new TypeError('The data argument must be a buffer source'));
        return;
      }
      const digest = nodeCrypto.createHash(which).update(bytes).digest();
      const out = new Uint8Array(digest.length);
      for (let i = 0; i < digest.length; i++) out[i] = digest[i];
      resolve(out.buffer);
    });
  }
}
Object.defineProperty(SubtleCrypto.prototype, Symbol.toStringTag, { value: 'SubtleCrypto', configurable: true });

const subtle = new SubtleCrypto();
const crypto = new Crypto();

module.exports = { crypto: crypto, Crypto: Crypto, SubtleCrypto: SubtleCrypto };
";
}

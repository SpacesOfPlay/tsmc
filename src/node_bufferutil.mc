// node_bufferutil.mc -- the `bufferutil` and `utf-8-validate` modules.
//
// The two helpers a WebSocket implementation spends its time in: masking a
// frame's payload and checking that a text frame is UTF-8. Both are a loop
// over every byte of every message, which is the one thing not to do in
// interpreted code, so they are built in over native byte helpers. The
// packages of these names are native addons, which cannot be loaded here,
// and the `ws` package asks for them by name and uses whichever answers.
//
// Embedded JS: no backslash escapes (minc processes them in string literals)
// and no double quotes.

str node_bufferutil_source() {
    return "'use strict';

// output[offset + i] = source[i] ^ mask[i & 3], for `length` bytes
function mask(source, mask, output, offset, length) {
  __buf_mask(source, mask, output, offset, length);
}

// buffer[i] ^= mask[i & 3], in place
function unmask(buffer, mask) {
  __buf_unmask(buffer, mask);
}

module.exports = { mask: mask, unmask: unmask };
";
}

str node_utf8validate_source() {
    return "'use strict';

function isValidUTF8(buffer) {
  return __utf8_valid(buffer);
}

// the module is the function; newer callers read it as a property too
isValidUTF8.isValidUTF8 = isValidUTF8;
module.exports = isValidUTF8;
";
}

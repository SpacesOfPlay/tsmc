// zlib: round-trips (deterministic) + cross-engine decompression of a
// Node-produced gzip blob. Compressed bytes differ across DEFLATE encoders
// (expected), so we compare recovered data, not compressed output.
const zlib = require("zlib");
const s = "The quick brown fox jumps over the lazy dog. ".repeat(4);

console.log("gzip rt:", zlib.gunzipSync(zlib.gzipSync(s)).toString() === s);
console.log("zlib rt:", zlib.inflateSync(zlib.deflateSync(s)).toString() === s);
console.log("raw rt:", zlib.inflateRawSync(zlib.deflateRawSync(s)).toString() === s);
console.log("buffer in:", zlib.gunzipSync(zlib.gzipSync(Buffer.from(s))).toString() === s);
console.log("empty:", zlib.gunzipSync(zlib.gzipSync("")).length);
console.log("short:", zlib.inflateSync(zlib.deflateSync("hi")).toString());

// decompress a fixed, Node-produced gzip blob (both engines -> the same text)
const blob = Buffer.from("H4sIAAAAAAAACgvJSFUoLM1MzlZIKsovz1NIy69QyCrNLShWyC9LLVIoyUhVyEmsqlRIyU/XUwgZHIoBG43/RLQAAAA=", "base64");
console.log("fixed gzip:", zlib.gunzipSync(blob).toString() === s, zlib.gunzipSync(blob).length);

// gzip output framing
const g = zlib.gzipSync(s);
console.log("magic:", g[0], g[1], g[2], Buffer.isBuffer(g));

// larger, more-compressible payload
const big = "x".repeat(5000);
console.log("big rt:", zlib.gunzipSync(zlib.gzipSync(big)).toString() === big, zlib.gzipSync(big).length < 200);

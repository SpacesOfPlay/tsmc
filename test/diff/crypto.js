// crypto: SHA-256 hashing (byte-identical to Node) + randomBytes /
// randomUUID (shape only — non-deterministic). require('crypto') works in
// Node CJS and tsmc alike.
const crypto = require("crypto");

// known + general vectors, hex
console.log(crypto.createHash("sha256").update("abc").digest("hex"));
console.log(crypto.createHash("sha256").update("").digest("hex"));
console.log(crypto.createHash("sha256").update("hello world").digest("hex"));

// encodings
console.log(crypto.createHash("sha256").update("data").digest("base64"));
const buf = crypto.createHash("sha256").update("data").digest();
console.log(Buffer.isBuffer(buf), buf.length, buf.toString("hex").slice(0, 12));

// multi-update accumulates == single update of the concatenation
console.log(crypto.createHash("sha256").update("hello").update(" ").update("world").digest("hex"));

// Buffer input + utf8 multibyte
console.log(crypto.createHash("sha256").update(Buffer.from([1, 2, 3])).digest("hex").slice(0, 12));
console.log(crypto.createHash("sha256").update("héllo 世界").digest("hex"));

// update() returns the hash (chaining)
const h = crypto.createHash("sha256");
console.log(h.update("x") === h);

// randomBytes / randomUUID: shape only
const rb = crypto.randomBytes(16);
console.log(Buffer.isBuffer(rb), rb.length, crypto.randomBytes(0).length);
const uuid = crypto.randomUUID();
console.log(uuid.length, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid));
console.log(crypto.randomUUID() !== crypto.randomUUID());

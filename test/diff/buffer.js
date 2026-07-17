// Buffer: array-backed, byte-indexable, with the common Node surface.
// Deterministic, so verified byte-identical against Node here.

// construction + encodings
const b = Buffer.from("Hello, 世界");
console.log(b.length, b[0], b.toString(), b.toString("hex"));
console.log(Buffer.from("48656c6c6f", "hex").toString());
console.log(Buffer.from("SGVsbG8=", "base64").toString());
console.log(Buffer.from("Hello").toString("base64"), Buffer.from("Hello").toString("base64url"));
console.log(Buffer.from([72, 105, 33]).toString());
console.log(Buffer.from("café", "latin1").length, Buffer.from("abc", "ascii").toString("hex"));

// alloc + fill
console.log(Buffer.alloc(4).toString("hex"), Buffer.alloc(4, 0xab).toString("hex"));
console.log(Buffer.alloc(5, "xy").toString());

// concat, isBuffer, byteLength
console.log(Buffer.concat([Buffer.from("ab"), Buffer.from("cd")]).toString());
console.log(Buffer.isBuffer(b), Buffer.isBuffer([1, 2, 3]), Buffer.isBuffer("x"));
console.log(Buffer.byteLength("Hello, 世界"), Buffer.byteLength("SGVsbG8=", "base64"));

// slice / equals / compare / copy
const s = b.slice(0, 5);
console.log(s.toString(), s.equals(Buffer.from("Hello")), Buffer.isBuffer(s));
console.log(Buffer.from("abc").compare(Buffer.from("abd")), Buffer.from("abc").compare(Buffer.from("abc")));
const t = Buffer.alloc(3);
console.log(Buffer.from("xyz").copy(t), t.toString());

// write / fill / indexOf / includes
const w = Buffer.alloc(10);
console.log(w.write("hi"), w.toString("utf8", 0, 2));
console.log(Buffer.from("hello world").indexOf("world"), Buffer.from("hello").indexOf("z"));
console.log(Buffer.from("hello").includes("ell"), Buffer.from([1, 2, 3]).indexOf(2));

// numeric reads / writes
const n = Buffer.alloc(4);
n.writeUInt32BE(0x01020304, 0);
console.log(n.toString("hex"), n.readUInt32BE(0), n.readUInt32LE(0));
const m = Buffer.alloc(2);
m.writeUInt16LE(0x0102, 0);
console.log(m.toString("hex"), m.readUInt16LE(0), m.readUInt16BE(0));
console.log(Buffer.from([200]).readInt8(0), Buffer.from([200]).readUInt8(0));

// toJSON + JSON.stringify
console.log(JSON.stringify(Buffer.from([1, 2, 3])));

// indexing write, iteration
const idx = Buffer.from([10, 20, 30]);
idx[1] = 99;
console.log(idx[1], [...idx].join(","));

// TextEncoder / TextDecoder over UTF-8 (+ latin1 decode).
const enc = new TextEncoder();
console.log(enc.encoding, [...enc.encode("héllo")].join(","));
console.log([...enc.encode("世界")].join(","), enc.encode("").length, enc.encode().length);

const dec = new TextDecoder();
console.log(dec.encoding, dec.decode(enc.encode("round trip 世界")));
console.log(new TextDecoder("utf-8").encoding, new TextDecoder("latin1").encoding);

// round-trip through a Buffer
const bytes = enc.encode("Café ☕");
console.log(bytes.length, new TextDecoder().decode(bytes));

// latin1 decode: bytes 0-255 map to code points
console.log(new TextDecoder("latin1").decode(Buffer.from([104, 233, 108, 108, 111])));

console.log(typeof enc, enc instanceof TextEncoder, dec instanceof TextDecoder);

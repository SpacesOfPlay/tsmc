// __filename / __dirname: absolute paths are host-varying, so assert
// their relationship and shape rather than the literal value.
console.log(typeof __filename, typeof __dirname);
console.log(__filename.length > 0, __dirname.length > 0);
console.log(__filename.endsWith("dirname.ts"));
console.log(__filename.startsWith(__dirname));
const sep = __filename.charAt(__dirname.length);
console.log(sep === "/" || sep === "\\");
console.log(__filename.slice(__dirname.length + 1) === "dirname.ts");
console.log(!__dirname.endsWith("/") && !__dirname.endsWith("\\"));
// module-local, like Node: not a globalThis property
console.log("__dirname" in globalThis, "__filename" in globalThis);

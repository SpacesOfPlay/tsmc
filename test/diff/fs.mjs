// Built-in `fs` sync subset. Round-trips real files in a per-process temp
// dir (pid keeps tsmc and node isolated). Prints only content / sizes /
// booleans (deterministic), never the host-specific paths, then cleans up.
import fs from "fs";
import path from "path";

const tmp = process.env.TEMP || process.env.TMPDIR || ".";
const dir = path.join(tmp, "tsmc_fs_" + process.pid);
fs.mkdirSync(dir, { recursive: true });

const f = path.join(dir, "hello.txt");
fs.writeFileSync(f, "Hello, world!");
console.log(fs.existsSync(f), fs.readFileSync(f, "utf8"));

const buf = fs.readFileSync(f);
console.log(buf.length, buf[0], Buffer.isBuffer(buf));

fs.appendFileSync(f, " More.");
console.log(fs.readFileSync(f, "utf8"));

const st = fs.statSync(f);
console.log(st.size, st.isFile(), st.isDirectory());
console.log(fs.statSync(dir).isDirectory(), fs.statSync(dir).isFile());

const dst = path.join(dir, "renamed.txt");
fs.renameSync(f, dst);
console.log(fs.existsSync(f), fs.existsSync(dst));

const bin = path.join(dir, "b.bin");
fs.writeFileSync(bin, Buffer.from([1, 2, 3, 255]));
console.log(fs.readFileSync(bin, "hex"), fs.statSync(bin).size);

// readdir (sorted — enumeration order is host-defined)
console.log(fs.readdirSync(dir).sort().join(","));

try { fs.readFileSync(path.join(dir, "nope.txt")); console.log("no throw"); }
catch (e) { console.log(e.message.includes("ENOENT"), e.code); }

// cleanup
fs.unlinkSync(dst);
fs.unlinkSync(bin);
fs.rmdirSync(dir);
console.log(fs.existsSync(dir));

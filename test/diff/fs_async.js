// Async fs: fs.promises, the fs/promises module, and the callback API.
// Real files in a per-process temp dir; prints only content/sizes/booleans
// (deterministic), never host paths. Operations are awaited/sequenced.
const fs = require("fs");
const fsp = require("fs/promises");
const path = require("path");
const dir = path.join(process.env.TEMP || process.env.TMPDIR || ".", "tsmc_fsa_" + process.pid);

async function main() {
  await fsp.mkdir(dir, { recursive: true });
  const f = path.join(dir, "a.txt");

  await fs.promises.writeFile(f, "hello");
  console.log("promises read:", await fs.promises.readFile(f, "utf8"));

  await fsp.appendFile(f, " world");
  console.log("fsp read:", await fsp.readFile(f, "utf8"));

  const st = await fsp.stat(f);
  console.log("stat:", st.size, st.isFile(), st.isDirectory());
  console.log("readdir:", (await fsp.readdir(dir)).sort().join(","));

  // buffer result (no encoding)
  const buf = await fsp.readFile(f);
  console.log("buffer:", Buffer.isBuffer(buf), buf.length);

  // rejection with .code
  try { await fsp.readFile(path.join(dir, "nope")); console.log("no throw"); }
  catch (e) { console.log("rejected:", e.code); }

  // callback API, sequenced
  await new Promise((res) => fs.readFile(f, "utf8", (err, data) => { console.log("cb read:", err, data); res(); }));
  await new Promise((res) => fs.writeFile(f, "cb-write", (err) => { console.log("cb write:", err, fs.readFileSync(f, "utf8")); res(); }));
  await new Promise((res) => fs.readFile(path.join(dir, "nope"), (err) => { console.log("cb err:", err.code); res(); }));
  await new Promise((res) => fs.stat(f, (err, s) => { console.log("cb stat:", err, s.size); res(); }));

  await fsp.unlink(f);
  await fsp.rmdir(dir);
  console.log("cleaned:", fs.existsSync(dir));
}
main().catch((e) => console.log("FAIL", e && e.message));

// process: host-varying values (pid, cwd, argv paths, env) can't be
// golden-compared, so we assert types and invariants instead. Run with
// no extra arguments, so argv is [execPath, scriptPath].
console.log(typeof process, typeof process.argv, Array.isArray(process.argv), process.argv.length >= 2);
console.log(typeof process.argv[0] === "string", typeof process.argv[1] === "string");
console.log(["win32", "linux", "darwin"].includes(process.platform));
console.log(["x64", "arm64"].includes(process.arch));
console.log(typeof process.pid === "number", process.pid > 0);
console.log(typeof process.env === "object", Object.keys(process.env).length >= 0);
console.log(process.version[0] === "v", typeof process.versions.node === "string", process.versions.tsmc);
console.log(typeof process.cwd() === "string", process.cwd().length > 0);
console.log(typeof process.stdout.write === "function", process.stdout.write("stdout write reached\n"));
process.stderr.write("stderr write reached (not compared)\n");

const h = process.hrtime();
console.log(Array.isArray(h), h.length === 2, typeof h[0] === "number", typeof h[1] === "number");
const d = process.hrtime(h);
console.log(d[0] >= 0, d[1] >= 0, typeof process.hrtime.bigint() === "bigint");

const order: string[] = [];
process.nextTick(() => order.push("tick"));
process.nextTick((x) => order.push("tick:" + x), "arg");
Promise.resolve().then(() => order.push("promise"));
order.push("sync");
setTimeout(() => console.log(order.join(",")), 0);

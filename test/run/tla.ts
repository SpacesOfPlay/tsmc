// Top-level await in an ES module (the import triggers module mode). The
// module body compiles as an async coroutine that the event loop drains.
import path from "path";
console.log("a", typeof path.join);

const v = await Promise.resolve(10);
console.log("b", v);

// for await ... of over a mix of promises and plain values
const arr: number[] = [];
for await (const x of [Promise.resolve(1), Promise.resolve(2), 3]) arr.push(x);
console.log("c", arr.join(","));

// await inside expressions, and a nested async function's await is independent
const sum = (await Promise.resolve(4)) + (await Promise.resolve(5));
console.log("d", sum);

async function nested() { return await Promise.resolve("deep"); }
console.log("e", await nested());

// await in a loop
let total = 0;
for (let i = 0; i < 3; i++) total += await Promise.resolve(i);
console.log("f", total);

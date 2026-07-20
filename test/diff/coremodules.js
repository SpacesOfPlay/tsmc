// Core-module forms of globals: process / buffer / timers, plus the
// awaitable timers/promises. require() works in Node CJS and tsmc alike.
const os = require("os");
const process = require("process");
const buffer = require("buffer");
const { Buffer } = require("buffer");
const timers = require("timers");
const { setTimeout: sleep, setImmediate: immediate } = require("timers/promises");

console.log("process default:", typeof process.env, process.platform === os.platform(), typeof process.cwd);
console.log("buffer:", Buffer.from("hi").toString("hex"), buffer.Buffer === Buffer);
console.log("timers:", typeof timers.setTimeout, typeof timers.clearTimeout, typeof timers.setInterval);

async function main() {
  console.log("sleep:", await sleep(5, "value"));
  console.log("immediate:", await immediate("imm"));
  const order = [];
  await sleep(1); order.push(1);
  await sleep(1); order.push(2);
  await sleep(1); order.push(3);
  console.log("sequence:", order.join(""));
}
main();

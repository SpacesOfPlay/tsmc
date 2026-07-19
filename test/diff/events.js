// events / EventEmitter. require('events') is the class itself (Node CJS
// and tsmc both run a .js file as CommonJS).
const EventEmitter = require("events");
console.log(EventEmitter === EventEmitter.EventEmitter, typeof EventEmitter);

// on / emit: order, args, return value, this-binding
const ee = new EventEmitter();
const log = [];
ee.on("data", function (x) { log.push("a:" + x + ":" + (this === ee)); });
ee.on("data", (x) => log.push("b:" + x));
console.log(ee.emit("data", 7), log.join(","), ee.listenerCount("data"));

// once fires exactly once then detaches
const ee2 = new EventEmitter();
let n = 0;
ee2.once("go", () => n++);
ee2.emit("go"); ee2.emit("go");
console.log(n, ee2.listenerCount("go"));

// off (incl. removing a once by original), removeAllListeners
const f = () => {};
const ee3 = new EventEmitter();
console.log(ee3.on("x", f).on("x", () => {}) === ee3, ee3.listenerCount("x"));
ee3.off("x", f);
console.log(ee3.listenerCount("x"));
ee3.once("y", f);
ee3.off("y", f);
console.log(ee3.listenerCount("y"));

// prepend order
const ee4 = new EventEmitter();
const order = [];
ee4.on("e", () => order.push(2));
ee4.prependListener("e", () => order.push(1));
ee4.prependOnceListener("e", () => order.push(0));
ee4.emit("e");
console.log(order.join(""));

// eventNames / listeners (once unwrapped) / rawListeners
const ee5 = new EventEmitter();
ee5.on("a", f); ee5.once("a", () => {}); ee5.on("b", () => {});
console.log(ee5.eventNames().sort().join(","), ee5.listeners("a").length, ee5.listeners("a")[0] === f);

// unknown event -> false; 'error' with no listener throws
console.log(ee5.emit("nope"));
function why(fn) { try { fn(); return "no throw"; } catch (e) { return "threw:" + e.message; } }
console.log(why(() => new EventEmitter().emit("error", new Error("boom"))));

// max listeners
console.log(new EventEmitter().getMaxListeners());

// subclassing: class X extends EventEmitter
class Bus extends EventEmitter {
  constructor() { super(); this.name = "bus"; }
  send(m) { this.emit("msg", m); return this; }
}
const bus = new Bus();
let got = null;
bus.on("msg", (m) => (got = m));
bus.send("hi");
console.log(bus instanceof EventEmitter, bus instanceof Bus, bus.name, got);

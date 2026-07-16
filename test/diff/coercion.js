console.log(1 + "2", "3" + 4, "5" * "6", "7" - "3", +"8", +"");
console.log(1 == "1", 0 == "", 0 == false, null == undefined, null == 0);
console.log(NaN == NaN, [] == "", [] == 0, [1] == 1, [1, 2] == "1,2");
console.log(true + 1, false + "", null + 1, undefined + 1);
console.log("" + null, "" + undefined, "" + true, "" + [], "" + [1, 2], "" + {});
console.log(!!"", !!"a", !!0, !!1, !!null, !!undefined, !![], !!{});
console.log(1 < 2, "a" < "b", "10" < "9", 10 < 9, "10" < 9);
console.log([1, 2, 3] + [4, 5], {} + [], typeof (1 + "2"));
console.log(5 & "3", "5" | 2, ~"5", "10" >> 1);
console.log(parseInt("  0x1F  "), Number(" 42 "), Number("1e3"), Number("Infinity"));
console.log(String([1, [2, [3]]]), String(null), String(undefined), String(Symbol ? "sym" : "no"));
console.log(0.1 + 0.2 === 0.3, 0.1 + 0.2, (0.1 + 0.2).toFixed(1));
console.log([] + {}, {} + [] === "[object Object]");
console.log(1 / "a", "5" % 3, 2 ** "3", -"5");
console.log(Boolean(""), Boolean("false"), Boolean(0), Boolean(NaN), Boolean([]));
console.log([3, 1, 10, 2].sort().join(","));
console.log(["b", "a", "c"].sort().join(","));
console.log([10, 9, 8, 100, 1].sort().join(","));
// primitive-wrapper objects unwrap via valueOf/toString
console.log(new Number(1) + 1, new Number(2) * 3, new Number(5).valueOf());
console.log(new Boolean(true) + "", new Boolean(false).valueOf(), (true).toString());
console.log(new String("hi").length, new String("ab").toUpperCase(), new String("x") + "y");
console.log(`${new Number(7)}-${new Boolean(true)}`, new Number(255).toString(16));
console.log(new Number(5) == 5, new Number(5) === 5, new String("a") == "a");
console.log(typeof new Number(1), new Number(3).toFixed(2), (9).valueOf());
// implicit Symbol coercion is a TypeError; explicit String()/toString() is not
function symThrows(f) { try { f(); return false; } catch (e) { return e instanceof TypeError; } }
console.log(symThrows(() => "" + Symbol()), symThrows(() => Symbol() + 1), symThrows(() => `${Symbol()}`));
console.log(symThrows(() => Number(Symbol())), symThrows(() => +Symbol()), symThrows(() => Symbol() < 1));
console.log(symThrows(() => Symbol() & 1), symThrows(() => [Symbol()].join(",")), symThrows(() => new String(Symbol())));
console.log(String(Symbol("x")), Symbol("y").toString(), typeof Symbol());
console.log(Symbol() == 1, (function(){ var s = Symbol(); return s == s; })());
// Symbol.toPrimitive is consulted first, with the correct hint
var prim = { [Symbol.toPrimitive](hint) { return hint === "number" ? 42 : hint === "string" ? "S" : "D"; } };
console.log(+prim, prim * 2, prim - 0, prim < 100, `${prim}`, "" + prim, prim + 1, prim == "D");
console.log(typeof Symbol.toPrimitive, `${{ toString() { return "ts"; } }}`);
// unary +/- ToPrimitive objects via valueOf
var vo = { valueOf() { return 7; } };
console.log(+vo, -vo, vo * 3, `${vo}`);
// Date: default/string hint -> string form; number hint -> timestamp
var dt = new Date(0);
console.log((dt + dt) === (dt.toString() + dt.toString()), typeof (+dt), +dt === dt.getTime());
// toPrimitive returning an object throws
console.log((function(){ try { return "" + { [Symbol.toPrimitive]() { return {}; } }; } catch (e) { return e instanceof TypeError; } })());

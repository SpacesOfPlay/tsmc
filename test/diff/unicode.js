// UTF-16 string semantics over UTF-8 storage.

// length: BMP counts as 1 unit, astral as 2
console.log("café".length, "日本語".length, "naïve".length, "abc".length);
console.log("😀".length, "a😀b".length, "😀😀".length, "𝐇𝐞𝐥𝐥𝐨".length);
console.log("①②③".length, "Ａ".length, "é".length);

// indexing and charAt / charCodeAt / codePointAt
console.log("café"[3], "café".charAt(3), "café"[2]);
console.log("café".charCodeAt(3), "日本語".charCodeAt(1), "abc".charCodeAt(0));
console.log("😀".charCodeAt(0), "😀".charCodeAt(1), "😀".codePointAt(0));
console.log("a😀".codePointAt(1), "abc".codePointAt(0));

// slice / substring / substr / at (unit indices)
console.log("café".slice(1, 3), "日本語".slice(1), "héllo".substring(0, 3));
console.log("café".substr(1, 2), "a😀b".slice(1, 3), "a😀b".at(-1));
console.log("café".at(-1), "abc".at(0));

// search returns/accepts unit indices
console.log("café".indexOf("é"), "héllo wörld".indexOf("wörld"), "abc".indexOf("z"));
console.log("café".lastIndexOf("é"), "aéaéa".lastIndexOf("é"));
console.log("café".includes("fé"), "日本語".startsWith("日"), "café".endsWith("é"));

// split / pad measured in units
console.log("café".split("").join("|"), "😀".split("").length);
console.log("é".padStart(4, "*"), "abc".padStart(5, "xy"), "x".padEnd(3));

// iteration yields code points
console.log([..."café"].join("|"), [..."a😀b"].length, [..."a😀b"].join(","));
console.log(Array.from("héllo").length, Array.from("😀😀").length);
console.log([..."𝐇𝐞𝐥𝐥𝐨"].length, "𝐇𝐞𝐥𝐥𝐨".length);
for (const ch of "a😀b") console.log(ch);

// fromCharCode (code units) / fromCodePoint (code points)
console.log(String.fromCharCode(72, 105), String.fromCharCode(233));
console.log(String.fromCharCode(0xd83d, 0xde00), String.fromCharCode(0xd83d, 0xde00).length);
console.log(String.fromCodePoint(128512), String.fromCodePoint(97, 98));
console.log(String.fromCodePoint(0x1f600) === "😀");

// Set/Map from string and other iterables
console.log([...new Set("aabbc")].join(""));
console.log([...new Set("😀a😀")].length);
console.log(new Map([["k", 1]]).get("k"));

// concatenation and templates preserve unit length
console.log(("ca" + "fé").length, (`${"日"}本語`).length);
console.log("é".repeat(3), "é".repeat(3).length);

// Latin-1 case mapping
console.log("café".toUpperCase(), "CAFÉ".toLowerCase());
console.log("àéîõü".toUpperCase(), "ÀÉÎÕÜ".toLowerCase());
console.log("naïve RÉSUMÉ".toLowerCase(), "hello wörld".toUpperCase());
console.log("straße".toUpperCase(), "ÿ".toUpperCase(), "Ÿ".toLowerCase());

// Unicode escapes in identifiers and property names (ES 12.6)
var obj = { def\u{61}ult: 1, abc: 2 };
console.log(obj.default, obj.abc);
var ca\u{66}e = 42;
console.log(cafe, cafe);
var xy = 7;
console.log(xy);
console.log({ \u{66}oo: "bar" }.foo);
class Cls { method() { return 9; } }
console.log(new Cls().method());

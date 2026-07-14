const words: string[] = "the quick brown fox".split(" ");
console.log(words.length);
console.log(words.map((w: string) => w.toUpperCase()).join(","));
console.log("abc".padStart(5, "-"));
console.log("hello world".replace("world", "there"));

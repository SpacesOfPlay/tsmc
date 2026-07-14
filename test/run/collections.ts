const inventory = new Map<string, number>();
inventory.set("apple", 5);
inventory.set("banana", 3);
inventory.set("apple", inventory.get("apple")! + 2);
console.log("apple:", inventory.get("apple"), "items:", inventory.size);

const unique = new Set<number>();
[3, 1, 4, 1, 5, 9, 2, 6, 5, 3].forEach((n) => unique.add(n));
console.log("unique:", [...unique].sort((a, b) => a - b).join(","));

const tags = new Set(["ts", "minc"]);
console.log("has ts:", tags.has("ts"), "has js:", tags.has("js"));

const start = new Date(2024, 5, 15);
console.log("day of week:", start.getDay(), "month:", start.getMonth() + 1);

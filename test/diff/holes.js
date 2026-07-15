// Sparse arrays: holes are absent, distinct from stored undefined.

// creation and length
console.log([1, , 3].length, [, , ].length, [1, 2, , ].length);
console.log(Array(3).length, Array(0).length);

// holes are not own keys
console.log(Object.keys([1, , 3]).join(","), Object.keys(Array(3)).length);
console.log(1 in [1, , 3], 0 in [1, , 3], [1, , 3].hasOwnProperty(1));
console.log(Object.getOwnPropertyNames([1, , 3]).join(","));
console.log(Object.values([1, , 3]).join(","), Object.entries([1, , 3]).length);

// assignment past the end creates holes
const a = [];
a[3] = 1;
console.log(a.length, Object.keys(a).join(","), 0 in a, JSON.stringify(a));

// for-in and spread
let keys = "";
for (const k in [1, , 3]) keys += k;
console.log(keys, [...[1, , 3]].length);

// reads: hole is undefined but not an own property
console.log([1, , 3][1] === undefined, typeof [1, , 3][1]);

// methods that SKIP holes
let count = 0;
[1, , 3].forEach(() => count++);
console.log(count);
console.log(JSON.stringify([1, , 3].map((x) => x * 2)));
console.log(Object.keys([1, , 3].map((x) => x * 2)).join(","));
console.log([1, , 3].filter(() => true).length);
console.log([1, , 3].some((x) => x === undefined), [1, , 3].every((x) => x > 0));
console.log([1, , 3].reduce((s, x) => s + x, 0), [1, , 3].reduceRight((s, x) => s + x));
console.log([1, , 3].indexOf(undefined));

// methods that VISIT holes as undefined
console.log([1, , 3].includes(undefined));
console.log([1, , 3].find((x) => x === undefined), [1, , 3].findIndex((x) => x === undefined));
console.log([1, , 3].join("-"), [3, , 1].reverse().join("-"));
console.log(JSON.stringify([1, , 3].fill(9)), Object.keys([1, , 3].fill(9)).length);

// slice / concat preserve holes
console.log(Object.keys([1, , 3].slice()).join(","));
console.log(Object.keys([1, , 3].concat([4])).join(","));
console.log(Object.keys([1, , 3].slice(0, 2)).join(","));

// console display coalesces holes
console.log([1, , 3]);
console.log([1, , , 4]);
console.log(Array(3));
console.log([1, 2, 3]);

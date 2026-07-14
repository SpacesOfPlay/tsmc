const data = { name: "tsmc", tags: ["ts", "minc"], version: 1 };
const text = JSON.stringify(data);
console.log(text);
const back = JSON.parse(text) as any;
console.log(back.tags[1]);
console.log(JSON.stringify({ a: [1, 2] }, null, 2));

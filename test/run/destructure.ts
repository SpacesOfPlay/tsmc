const config = { host: "localhost", port: 8080, tags: ["a", "b", "c"] };
const { host, port = 80, missing = "none", tags: [firstTag, ...restTags] } = config;
console.log(host, port, missing);
console.log(firstTag, restTags.length);

function stats(...nums: number[]): { min: number; max: number } {
    let min = nums[0];
    let max = nums[0];
    for (const n of nums) {
        if (n < min) min = n;
        if (n > max) max = n;
    }
    return { min, max };
}
const { min, max } = stats(5, 2, 9, 4);
console.log(min, max);

const base = { a: 1, b: 2 };
const extended = { ...base, c: 3 };
console.log(JSON.stringify(extended));

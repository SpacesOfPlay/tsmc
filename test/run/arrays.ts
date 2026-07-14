const nums: number[] = [5, 3, 8, 1];
nums.sort((a: number, b: number) => a - b);
console.log(nums.join(" "));
const doubled = nums.map((n: number) => n * 2).filter((n: number) => n > 5);
console.log(doubled.join(" "));
console.log(nums.reduce((a: number, b: number) => a + b, 0));

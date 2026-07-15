let total = 0;
for (let iter = 0; iter < 3000; iter++) {
    const a: number[] = [];
    for (let i = 0; i < 50; i++) { a.push(i); }
    total += a.map((x) => x * 2).filter((x) => x % 3 === 0).reduce((s, x) => s + x, 0);
}
console.log(total);

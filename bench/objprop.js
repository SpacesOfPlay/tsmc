// object property churn: build wide objects, read them back
let sum = 0;
for (let iter = 0; iter < 7400; iter++) {
    const o = {};
    for (let i = 0; i < 40; i++) { o["k" + i] = i; }
    for (let i = 0; i < 40; i++) { sum += o["k" + i]; }
}
console.log(sum);

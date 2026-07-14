function counter(): () => number {
    let n = 0;
    return function () {
        n = n + 1;
        return n;
    };
}
const c = counter();
console.log(c());
console.log(c());
console.log(c());

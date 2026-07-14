function* fib(): Generator<number> {
    let [a, b] = [0, 1];
    while (true) {
        yield a;
        [a, b] = [b, a + b];
    }
}

const out: number[] = [];
const it = fib();
for (let i = 0; i < 10; i++) {
    out.push(it.next().value);
}
console.log(out.join(" "));

function* take<T>(gen: Iterator<T>, n: number): Generator<T> {
    for (let i = 0; i < n; i++) {
        const r = gen.next();
        if (r.done) return;
        yield r.value;
    }
}
console.log([...take(fib(), 5)].join(","));

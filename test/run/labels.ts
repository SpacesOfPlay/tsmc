// labeled break/continue must target the named loop, not the innermost
const out: number[] = [];
outer: for (let x = 0; x < 4; x++) {
    for (let y = 0; y < 4; y++) {
        if (y === 2) continue outer;
        if (x === 3) break outer;
        out.push(x * 10 + y);
    }
}
console.log(out.join(","));

let found = "";
search: for (const row of [[1, 2], [3, 4], [5, 6]]) {
    for (const v of row) {
        if (v === 4) { found = "found at " + v; break search; }
    }
}
console.log(found);

block: {
    console.log("before");
    if (1 < 2) break block;
    console.log("unreachable");
}
console.log("after");

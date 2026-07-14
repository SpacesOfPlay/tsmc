function risky(v: unknown): number {
    if (typeof v !== "number") {
        throw new TypeError("expected a number");
    }
    return (v as number) * 2;
}
try {
    risky("nope");
} catch (e) {
    if (e instanceof TypeError) {
        console.log("caught: " + (e as Error).message);
    }
}
console.log(risky(21));

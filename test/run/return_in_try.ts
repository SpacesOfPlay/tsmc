// Regression: a `return` inside a `try` must pop that try's exception
// handler. If it leaks, a later `throw` in an enclosing scope unwinds
// into the already-returned frame's `catch` instead of the correct one.

function inner(): number {
    try {
        return 1;
    } catch (e) {
        return -999; // must never run
    }
}

function outer(): void {
    inner();
    throw new Error("real");
}

try {
    outer();
} catch (e) {
    console.log("caught:", (e as Error).message);
}

// Several in-try returns, then a throw caught in the same function.
function classify(x: number): string {
    if (x > 0) {
        try {
            return "pos";
        } catch (e) {
            return "bad";
        }
    }
    try {
        throw new Error("boom");
    } catch (e) {
        return "caught-" + (e as Error).message;
    }
}

console.log(classify(5), classify(-5));

// Finally still runs on an in-try return.
function withFinally(): string {
    const order: string[] = [];
    try {
        try {
            return order.join("");
        } finally {
            order.push("A");
        }
    } finally {
        order.push("B");
    }
}
console.log("finally:", withFinally() === "");

console.log("done");

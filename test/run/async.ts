function delay<T>(value: T): Promise<T> {
    return new Promise((resolve) => setTimeout(() => resolve(value), 10));
}

async function main(): Promise<void> {
    console.log("start");
    const a = await delay(1);
    const b = await delay(2);
    console.log("awaited", a + b);
    const all = await Promise.all([delay(10), delay(20), delay(30)]);
    console.log("all", all.join("+"), "=", all.reduce((x, y) => x + y, 0));
}

main().then(() => console.log("done"));
console.log("sync");

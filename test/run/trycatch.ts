function boom(): never {
    throw { name: "Oops", message: "bad" };
}
try {
    boom();
} catch (e) {
    console.log("caught " + (e as any).message);
} finally {
    console.log("done");
}

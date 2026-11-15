// `await` right after the `=>` of an async arrow, with the arrow in a
// position where a comma or a bracket follows its body: the body's first
// token is read in the arrow's own context.
const t = (x: number) => x;

const f = async (e: number) => await t(e);
const g = async e => await t(e);
const list = [async (e: number) => await t(e), 2];
const pair = (async (e: number) => await t(e), 3);
const obj: any = {};
obj.load = async (e: number) => await t(e), obj.tag = "set";

// and the other way round: in script code `await` is a name, so a plain
// arrow may take it as a parameter
const plain = (await: number) => await + 1;

Promise.all([f(1), g(2), list[0](3), obj.load(4)]).then((v) => {
    console.log("values", v.join(","), list[1], pair, obj.tag);
    console.log("plain", plain(1));
    console.log("done");
});

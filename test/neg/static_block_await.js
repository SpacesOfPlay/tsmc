// expect: await
async function f() { class C { static { await 0; } } }

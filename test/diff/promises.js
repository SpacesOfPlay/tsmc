// Promise combinators. Output is ordered so it matches Node's microtask
// scheduling deterministically.

async function main() {
  console.log("all:", (await Promise.all([1, Promise.resolve(2), 3])).join(","));

  const settled = await Promise.allSettled([
    Promise.resolve("ok"),
    Promise.reject("bad"),
    42,
  ]);
  console.log("allSettled:", JSON.stringify(settled));
  console.log("allSettled empty:", JSON.stringify(await Promise.allSettled([])));

  console.log("race:", await Promise.race([Promise.resolve("fast"), Promise.resolve("slow")]));

  console.log("any:", await Promise.any([Promise.reject(1), Promise.resolve("won"), 3]));

  try {
    await Promise.any([Promise.reject("x"), Promise.reject("y")]);
  } catch (e) {
    console.log("any all-rejected:", e.name, e instanceof Error, JSON.stringify(e.errors));
  }

  try {
    await Promise.any([]);
  } catch (e) {
    console.log("any empty:", e.name, JSON.stringify(e.errors));
  }
}

main().then(() => console.log("done"));

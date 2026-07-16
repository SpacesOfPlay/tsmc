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

  // for await: async generator, array of promises, break/continue
  async function* ag() { yield 1; yield 2; yield 3; }
  let s = 0;
  for await (const x of ag()) s += x;
  console.log("for-await gen:", s);
  const collected = [];
  for await (const v of [Promise.resolve("p"), "q", Promise.resolve("r")]) collected.push(v);
  console.log("for-await promises:", collected.join(","));
  const kept = [];
  for await (const z of ag()) { if (z === 2) continue; if (z > 2) break; kept.push(z); }
  console.log("for-await break/continue:", kept.join(","));
}

main().then(() => console.log("done"));

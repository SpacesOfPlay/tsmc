// `async function` as an expression, in every position it can appear.
// `async` is a contextual keyword, so the parser has to prefer the
// async-function form over treating `async` as a plain identifier.

const anon = async function () { return 1; };
const named = async function inner() { return 2; };
const rest = async function (...a) { return a.length; };
const obj = { m: async function () { return 4; } };
const arr = [async function () { return 5; }];
function take(f) { return f; }
const passed = take(async function () { return 6; });
const iife = (async function () { return 7; })();

// Generators too: `async function*`.
const agen = async function* () { yield 8; yield 9; };

(async () => {
  console.log('anon:', await anon());
  console.log('named:', await named(), named.name);
  console.log('rest:', await rest(1, 2, 3));
  console.log('object property:', await obj.m());
  console.log('array element:', await arr[0]());
  console.log('call argument:', await passed());
  console.log('iife:', await iife);

  const out = [];
  for await (const v of agen()) { out.push(v); }
  console.log('async generator:', out.join(','));

  // A named async function expression can call itself.
  const fact = async function f(n) { return n <= 1 ? 1 : n * (await f(n - 1)); };
  console.log('self-reference:', await fact(5));

  // `async` still works as an ordinary identifier and property name.
  const async = 10;
  console.log('as identifier:', async);
  console.log('as property:', { async: 11 }.async);
  const o = { async: 12 };
  console.log('as key:', o['async']);

  // The other async forms are unaffected.
  const arrow = async (x) => x * 2;
  console.log('arrow:', await arrow(6));
  const shorthand = { async m() { return 13; } };
  console.log('method shorthand:', await shorthand.m());
  console.log('declaration:', await decl());

  // async function expression assigned to a class field
  class C { f = async function () { return 14; }; }
  console.log('class field:', await new C().f());
})();

async function decl() { return 15; }

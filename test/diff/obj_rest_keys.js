// An object rest element copies the own enumerable properties the pattern did
// not take. A computed key is only known once it has run, so the list of what
// was taken is collected as the pattern goes, and the key is converted to a
// property key once — the read and the exclusion agree.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

T('a computed key', () => {
  const a = 'foo';
  let b, rest;
  ({ [a]: b, ...rest } = { foo: 1, bar: 2, baz: 3 });
  return JSON.stringify([b, rest]);
});
T('a numeric computed key', () => {
  const a = 1.;
  let b, rest;
  ({ [a]: b, ...rest } = { 1: 'one', bar: 2 });
  return JSON.stringify([b, rest]);
});
T('the same key spelled 1e0', () => {
  const a = 1e0;
  let b, rest;
  ({ [a]: b, ...rest } = { 1: 'one', bar: 2 });
  return JSON.stringify([b, rest]);
});
T('an array that stringifies to it', () => {
  const a = [1];
  let b, rest;
  ({ [a]: b, ...rest } = { 1: 'one', bar: 2 });
  return JSON.stringify([b, rest]);
});
T('a plain numeric key', () => {
  let b, rest;
  ({ 1: b, ...rest } = { 1: 'one', bar: 2 });
  return JSON.stringify([b, rest]);
});
T('a string-literal key', () => {
  let b, rest;
  ({ 'x y': b, ...rest } = { 'x y': 1, z: 2 });
  return JSON.stringify([b, rest]);
});
T('a symbol key', () => {
  const s = Symbol('s');
  let b, rest;
  ({ [s]: b, ...rest } = { [s]: 1, bar: 2 });
  return JSON.stringify([b, rest, Object.getOwnPropertySymbols(rest).length]);
});
T('several at once', () => {
  const k = 'b';
  let x, y, z, rest;
  ({ a: x, [k]: y, 3: z, ...rest } = { a: 1, b: 2, 3: 3, keep: 4 });
  return JSON.stringify([x, y, z, rest]);
});
T('a shorthand with a default', () => {
  let p = 0, rest;
  ({ p = 9, ...rest } = { q: 1 });
  return JSON.stringify([p, rest]);
});
T('the key is converted once', () => {
  let calls = 0;
  const k = { toString() { calls++; return 'a'; } };
  let b, rest;
  ({ [k]: b, ...rest } = { a: 1, c: 2 });
  return JSON.stringify([b, rest, calls]);
});
T('a declaration', () => {
  const a = 'foo';
  const { [a]: b, ...rest } = { foo: 1, bar: 2 };
  return JSON.stringify([b, rest]);
});
T('a parameter', () => (({ ['foo']: b, ...rest }) => JSON.stringify([b, rest]))({ foo: 1, bar: 2 }));
T('nested', () => {
  let b, rest;
  ({ inner: { ['k']: b, ...rest } } = { inner: { k: 1, other: 2 } });
  return JSON.stringify([b, rest]);
});
T('a string source, one index taken', () => {
  let taken, rest;
  ({ 0: taken, ...rest } = 'abc');
  return JSON.stringify([taken, rest]);
});
T('a string source, a computed index', () => {
  const i = 1;
  let taken, rest;
  ({ [i]: taken, ...rest } = 'abc');
  return JSON.stringify([taken, rest]);
});
T('rest alone', () => { let rest; ({ ...rest } = { a: 1 }); return JSON.stringify(rest); });
T('an inherited property stays behind', () => {
  const base = { inherited: 1 };
  const o = Object.create(base);
  o.own = 2;
  let rest;
  ({ ...rest } = o);
  return JSON.stringify(rest);
});
T('a non-enumerable one too', () => {
  const o = {};
  Object.defineProperty(o, 'hidden', { value: 1 });
  o.seen = 2;
  let rest;
  ({ ...rest } = o);
  return JSON.stringify(rest);
});
T('what the rest holds is a plain data property', () => {
  let b, rest;
  ({ a: b, ...rest } = { a: 1, keep: 2 });
  return JSON.stringify(Object.getOwnPropertyDescriptor(rest, 'keep'));
});
T('a getter is read, not copied', () => {
  let rest;
  ({ ...rest } = { get g() { return 5; }, plain: 1 });
  return JSON.stringify([rest.g, Object.getOwnPropertyDescriptor(rest, 'g')]);
});
T('no rest element, nothing collected', () => {
  const a = 'foo';
  let b;
  ({ [a]: b } = { foo: 7 });
  return b;
});
T('the pattern with no properties at all', () => {
  let rest;
  ({ ...rest } = { a: 1, b: 2 });
  return Object.keys(rest).join(',');
});

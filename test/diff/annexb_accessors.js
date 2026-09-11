// Annex B's __defineGetter__, __defineSetter__, __lookupGetter__ and
// __lookupSetter__. The pair they define is one accessor property, which
// means defineProperty has to keep the half a descriptor leaves out.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

T('they exist', () => [
  typeof ({}).__defineGetter__, typeof ({}).__defineSetter__,
  typeof ({}).__lookupGetter__, typeof ({}).__lookupSetter__,
].join(','));
T('their names', () => JSON.stringify([({}).__defineGetter__.name, ({}).__lookupSetter__.name]));
T('not enumerable on Object.prototype', () => Object.getOwnPropertyDescriptor(Object.prototype, '__defineGetter__').enumerable);

T('define a getter', () => { const o = {}; o.__defineGetter__('a', () => 42); return o.a; });
T('the descriptor it makes', () => {
  const o = {};
  const g = () => 1;
  o.__defineGetter__('a', g);
  const d = Object.getOwnPropertyDescriptor(o, 'a');
  return JSON.stringify([d.get === g, d.set, d.enumerable, d.configurable]);
});
T('define a setter', () => { const o = {}; let seen; o.__defineSetter__('a', (v) => { seen = v; }); o.a = 7; return seen; });
T('a getter and a setter make one property', () => {
  const o = {};
  let box = 0;
  o.__defineGetter__('a', () => box);
  o.__defineSetter__('a', (v) => { box = v * 2; });
  o.a = 3;
  return [o.a, Object.keys(o).length].join(',');
});
T('the same, through defineProperty', () => {
  const o = {};
  const g = () => 1;
  const s = () => {};
  Object.defineProperty(o, 'a', { get: g, configurable: true });
  Object.defineProperty(o, 'a', { set: s, configurable: true });
  const d = Object.getOwnPropertyDescriptor(o, 'a');
  return JSON.stringify([d.get === g, d.set === s]);
});
T('replacing only the getter', () => {
  const o = {};
  const s = () => {};
  Object.defineProperty(o, 'a', { get: () => 1, set: s, configurable: true });
  Object.defineProperty(o, 'a', { get: () => 2, configurable: true });
  const d = Object.getOwnPropertyDescriptor(o, 'a');
  return JSON.stringify([d.get(), d.set === s]);
});
T('an accessor becomes data', () => {
  const o = {};
  Object.defineProperty(o, 'a', { get: () => 1, configurable: true });
  Object.defineProperty(o, 'a', { value: 5 });
  const d = Object.getOwnPropertyDescriptor(o, 'a');
  return JSON.stringify([d.value, 'get' in d]);
});

T('not a function', () => { const o = {}; o.__defineGetter__('a', 1); return 'defined'; });
T('on null', () => Object.prototype.__defineGetter__.call(null, 'a', () => 1));
T('the key is coerced', () => { const o = {}; o.__defineGetter__({ toString: () => 'k' }, () => 5); return o.k; });
T('a symbol key', () => { const s = Symbol('s'); const o = {}; o.__defineGetter__(s, () => 6); return o[s]; });
T('over a non-configurable property', () => {
  const o = {};
  Object.defineProperty(o, 'a', { value: 1 });
  o.__defineGetter__('a', () => 2);
  return 'defined';
});
T('it returns undefined', () => { const o = {}; return typeof o.__defineGetter__('a', () => 1); });

T('look up an own getter', () => { const o = {}; const g = () => 1; o.__defineGetter__('a', g); return o.__lookupGetter__('a') === g; });
T('look up an inherited one', () => {
  const base = {};
  const g = () => 1;
  base.__defineGetter__('a', g);
  return Object.create(base).__lookupGetter__('a') === g;
});
T('a data property answers undefined', () => typeof ({ a: 1 }).__lookupGetter__('a'));
T('and stops the walk', () => {
  const base = {};
  base.__defineGetter__('a', () => 1);
  const o = Object.create(base);
  o.a = 2;
  return typeof o.__lookupGetter__('a');
});
T('an absent name', () => typeof ({}).__lookupGetter__('nope'));
T('a setter, and the getter that is not there', () => {
  const o = {};
  const s = () => {};
  o.__defineSetter__('a', s);
  return [o.__lookupSetter__('a') === s, typeof o.__lookupGetter__('a')].join(',');
});
T('on a primitive receiver', () => typeof 'abc'.__lookupGetter__('length'));
T('up the chain to Object.prototype', () => typeof ({}).__lookupGetter__('__proto__'));
T('on null', () => Object.prototype.__lookupGetter__.call(null, 'a'));

// a proxy answers for its own prototype, and its trap's error propagates
T('through a proxy trap', () => {
  const root = {};
  root.__defineGetter__('a', () => 1);
  const p = new Proxy({}, { getPrototypeOf: () => root });
  return typeof p.__lookupGetter__('a');
});
T('a throwing trap', () => {
  const root = Object.defineProperty({}, 'a', { get() {} });
  const p = new Proxy(Object.create(root), { getPrototypeOf() { throw new RangeError('no'); } });
  return p.__lookupGetter__('a');
});
T('getPrototypeOf consults the trap', () => {
  const alt = {};
  const p = new Proxy({}, { getPrototypeOf: () => alt });
  return [Object.getPrototypeOf(p) === alt, Reflect.getPrototypeOf(p) === alt].join(',');
});
T('and so does __proto__', () => {
  const alt = {};
  const p = new Proxy({}, { getPrototypeOf: () => alt });
  return p.__proto__ === alt;
});
T('no trap falls through to the target', () => {
  const base = {};
  const p = new Proxy(Object.create(base), {});
  return Object.getPrototypeOf(p) === base;
});

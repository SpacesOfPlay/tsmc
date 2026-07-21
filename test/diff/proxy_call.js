// Proxy apply/construct traps, callable-target typeof piercing,
// Array.isArray piercing, and Reflect.apply/construct. Compared against Node.
// (getPrototypeOf/setPrototypeOf/isExtensible/preventExtensions traps and
// array-target write-back are follow-ups.)

// apply trap, defaulting through Reflect.apply
const log = [];
const fn = (a, b) => a + b;
const p = new Proxy(fn, {
  apply(t, thisArg, args) { log.push('apply:' + args.join(',')); return Reflect.apply(t, thisArg, args); },
});
console.log(p(2, 3), typeof p);
console.log(log.join(' '));

// apply-absent defaults to calling the target
const q = new Proxy((x) => x * 10, {});
console.log(q(5), typeof q);

// this binding is threaded to the apply trap
const obj = { k: 100, m: new Proxy(function (a) { return this.k + a; }, {
  apply(t, thisArg, args) { return Reflect.apply(t, thisArg, args); },
}) };
console.log(obj.m(1));

// construct trap, defaulting through Reflect.construct
const C = function (n) { this.n = n; };
const pc = new Proxy(C, {
  construct(t, args) { const o = Reflect.construct(t, args); o.viaTrap = true; return o; },
});
const inst = new pc(7);
console.log(inst.n, inst.viaTrap, inst instanceof C);

// Array.isArray pierces a proxy-of-array; reads and iteration work
const pa = new Proxy([10, 20, 30], {});
console.log(Array.isArray(pa), typeof pa, pa.length, pa[1], [...pa].join(','));
console.log(Array.isArray(new Proxy(new Proxy([], {}), {})));   // nested pierces
console.log(Array.isArray(new Proxy({}, {})));                  // false

// a proxy over a plain object is not callable
console.log(typeof new Proxy({}, {}));
try { (new Proxy({}, {}))(); } catch (e) { console.log(e.constructor.name); }

// Reflect.apply / Reflect.construct directly
console.log(Reflect.apply((a, b, c) => a + b + c, null, [1, 2, 3]));
const made = Reflect.construct(function (x) { this.x = x; }, [42]);
console.log(made.x);

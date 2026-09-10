// A derived constructor owes exactly one super() call, and owes it before
// it returns: until then there is no instance to hand back. Returning an
// object of its own is the way out, and says the constructor meant it.

const at = (f) => { try { const v = f(); return 'ok:' + (v && v.tag ? v.tag : typeof v); } catch (e) { return e.constructor.name; } };

class Base { constructor(...args) { this.tag = 'base' + args.length; } }

class NoSuper extends Base { constructor() { } }
class ReturnsEarly extends Base { constructor() { return; } }
class ReturnsObject extends Base { constructor() { return { tag: 'its own' }; } }
class CallsTwice extends Base { constructor() { super(); super(); } }
class Conditional extends Base { constructor(yes) { if (yes) { super(1); } else { super(); } } }
class Spread extends Base { constructor() { super(...[1, 2]); } }
class Inherited extends Base { }
class Later extends Base { constructor() { const n = 1 + 1; super(n); this.extra = n; } }

console.log('no super:', at(() => new NoSuper()));
console.log('bare return:', at(() => new ReturnsEarly()));
console.log('returns an object:', at(() => new ReturnsObject()));
console.log('calls super twice:', at(() => new CallsTwice()));
console.log('either branch calls it:', at(() => new Conditional(true)), at(() => new Conditional(false)));
console.log('spread call:', at(() => new Spread()));
console.log('inherited constructor:', at(() => new Inherited()));
console.log('work before the call:', at(() => new Later()), new Later().extra);

// the rule is the derived constructor's own: a base class is unaffected,
// and so is anything else on the class
class Plain { constructor() { this.tag = 'plain'; } }
console.log('base class:', at(() => new Plain()));
class Methods extends Base {
  constructor() { super(); }
  *gen() { yield 1; }
  async run() { return 'ran'; }
  static make() { return new Methods(); }
}
console.log('methods:', at(() => Methods.make()), [...new Methods().gen()].join(','));

// a constructor that throws before super() reports its own error
class Throws extends Base { constructor() { throw new RangeError('mine'); } }
console.log('its own error wins:', at(() => new Throws()));

// subclassing a built-in follows the same rule
class BadArray extends Array { constructor() { } }
class GoodArray extends Array { constructor() { super(3); } }
// (the length a built-in base is constructed with is a separate gap)
console.log('builtin subclass:', at(() => new BadArray()), at(() => new GoodArray()));

// the instance is complete once the call has happened
class Fields extends Base { x = 'field'; constructor() { super(); this.y = 'after'; } }
const f = new Fields();
console.log('fields and assignments:', f.tag, f.x, f.y);

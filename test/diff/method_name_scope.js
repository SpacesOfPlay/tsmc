// A method's name is its property key, not a binding inside the body:
// `{ f() { f() } }` calls the outer f. A named function expression is
// the one form that sees itself.

function int(x) { return 'outer ' + x; }

const o = {
  int(x) { return this.tag + ':' + int(x); },
  tag: 'obj',
  get g() { return int('getter'); },
  set s(v) { this.last = int(v); },
  async a(x) { return int(x); },
  *gen() { yield int('gen'); },
  ['comp' + 'uted'](x) { return int(x); },
  int2: function int(x) { return x > 0 ? int(x - 1) : 'self ' + x; },
};
console.log(o.int(1), o.g, o.gen().next().value, o.computed(2));
o.s = 7;
console.log(o.last, o.int2(2));
console.log(o.int.name, o.int2.name);

class C {
  int(x) { return int(x); }
  static int(x) { return int(x); }
  get g() { return int('class getter'); }
}
console.log(new C().int(4), C.int(5), new C().g);

const f = function int(x) { return x > 0 ? int(x - 1) : 'self ok'; };
console.log(f(2), f.name);

o.a(3).then(v => console.log('async', v));

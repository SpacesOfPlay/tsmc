// Private brand checks: `#name in obj`. True when obj carries the private
// field/method/accessor, false for objects that don't, and a throw for a
// non-object right-hand side (like the ordinary `in` operator).

class Box {
  #val = 1;
  #method() { return this.#val; }
  get #acc() { return 5; }
  static isBox(o) { return #val in o; }
  static hasMethod(o) { return #method in o; }
  static hasAcc(o) { return #acc in o; }
  static describe(o) { return (#val in o) ? 'yes' : 'no'; }
  static lacks(o) { return !(#val in o); }
  has(o) { return #val in o; }
}

const b = new Box();
console.log('field:', Box.isBox(b), Box.isBox({}));
console.log('method:', Box.hasMethod(b), Box.hasMethod({}));
console.log('accessor:', Box.hasAcc(b), Box.hasAcc({}));
console.log('instance method:', b.has(b), b.has({}));

// A non-object right-hand side throws, like `in`.
try { Box.isBox(42); console.log('no throw'); } catch (e) { console.log('primitive:', e instanceof TypeError); }
try { Box.isBox(null); console.log('no throw'); } catch (e) { console.log('null:', e instanceof TypeError); }
try { Box.isBox('s'); console.log('no throw'); } catch (e) { console.log('string:', e instanceof TypeError); }

// A subclass instance carries the base class's brand.
class Sub extends Box {}
console.log('subclass:', Box.isBox(new Sub()));

// A different class (distinct private name) is not a brand of this one.
class Widget { #wid = 0; static isWidget(o) { return #wid in o; } }
console.log('cross-class:', Box.isBox(new Widget()), Widget.isWidget(b));

// A proxy over a branded instance is not itself branded, and the check does
// not trigger the proxy's `has` trap.
let trapped = false;
const p = new Proxy(b, { has() { trapped = true; return true; } });
console.log('proxy:', Box.isBox(p), 'trap fired:', trapped);

// Works in an ordinary expression / boolean context too (checked inside the
// class, where the private name is in scope).
console.log('ternary:', Box.describe(b), Box.describe({}));
console.log('negation:', Box.lacks({}), Box.lacks(b));

// A private name follows identifier rules: non-ASCII characters and Unicode
// escapes are allowed, and an escape names the same member as the literal
// character does.
class Escaped {
  #℘ = 'wp';
  #\u{6F} = 'oh';
  #ZW_‍_J = 'zwj';
  #\u{6D}() { return 'meth'; }
  read() { return [this.#℘, this.#o, this.#ZW_‍_J, this.#m()].join(','); }
  escapedIsSame() { return this.#\u{6F} === this.#o; }
  static brand(o) { return #\u{6F} in o; }
}
const esc = new Escaped();
console.log('unicode private:', esc.read());
console.log('escape aliases literal:', esc.escapedIsSame());
console.log('escaped brand:', Escaped.brand(esc), Escaped.brand({}));

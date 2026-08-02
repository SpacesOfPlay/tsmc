// Function.prototype.toString: the text a function was written as.
//
// Two idioms depend on this and fail quietly without it. Libraries read
// parameter names out of the source, and polyfills ask whether a builtin is
// still native by looking for "[native code]" in it.
//
// Node reports the source it parsed. For a .ts file tsmc reports the text
// with its type annotations, where node (which strips them) would not, so
// this test stays in .js.
//
// Not checked: Function.prototype itself. Node's is a callable that reports
// "function () { [native code] }", where tsmc's is a plain object, so
// typeof Function.prototype differs too.

const rows = [];
function T(label, fn) {
  let v;
  try { v = JSON.stringify(fn()); }
  catch (e) { v = 'THROW:' + (e && e.name ? e.name : String(e)); }
  rows.push(label + ' = ' + v);
}

// --- declarations and expressions -------------------------------------------
function decl(a, b) { return a + b; }
async function asy() {}
function* gen() { yield 1; }
async function* agen() { yield 1; }

T('decl', () => decl.toString());
T('async', () => asy.toString());
T('generator', () => gen.toString());
T('async-generator', () => agen.toString());
T('anon-expr', () => (function (a) { return a; }).toString());
T('named-expr', () => (function named(a) { return a; }).toString());
T('star-expr', () => (function* (a) { yield a; }).toString());
T('iife-inner', () => (function () { return function deep(q) { return q; }; })()().toString ? (function () { return function deep(q) { return q; }; })().toString() : 'x');

// --- arrows -----------------------------------------------------------------
const arrow = (x) => x * 2;
const arrowBlock = (x) => { return x; };
const arrowBare = x => x + 1;
const arrowNoArg = () => 42;
const arrowAsync = async (v) => v;
const arrowDefault = (a = 1, b = 2) => a + b;
const arrowDestructure = ({ a, b: [c] }) => a + c;

T('arrow', () => arrow.toString());
T('arrow-block', () => arrowBlock.toString());
T('arrow-bare-param', () => arrowBare.toString());
T('arrow-no-arg', () => arrowNoArg.toString());
T('arrow-async', () => arrowAsync.toString());
T('arrow-default', () => arrowDefault.toString());
T('arrow-destructure', () => arrowDestructure.toString());

// --- classes ----------------------------------------------------------------
class Klass {
  constructor(a) { this.a = a; }
  m(a) { return a; }
  static s() {}
  get g() { return 1; }
  set g(v) {}
  *itr() { yield 1; }
  async am() {}
  #priv() { return 1; }
  callPriv() { return this.#priv(); }
  static ['computed']() { return 2; }
}
class Derived extends Klass {}
const NamedExpr = class Inner { q() {} };

T('class', () => Klass.toString());
T('class-derived', () => Derived.toString());
T('class-expression', () => NamedExpr.toString());
T('method', () => Klass.prototype.m.toString());
T('static-method', () => Klass.s.toString());
T('static-excludes-static-keyword', () => Klass.s.toString().startsWith('s('));
T('getter', () => Object.getOwnPropertyDescriptor(Klass.prototype, 'g').get.toString());
T('setter', () => Object.getOwnPropertyDescriptor(Klass.prototype, 'g').set.toString());
T('generator-method', () => Klass.prototype.itr.toString());
T('async-method', () => Klass.prototype.am.toString());
T('computed-method', () => Klass.computed.toString());
T('class-in-object', () => ({ K: Klass }).K.toString().slice(0, 11));

// --- object literals --------------------------------------------------------
const obj = {
  meth(a) { return a; },
  get p() { return 1; },
  set p(v) {},
  *g2() { yield 2; },
  async a2() {},
  fnValue: function inner2(z) { return z; },
  arrowValue: (y) => y,
};

T('obj-method', () => obj.meth.toString());
T('obj-getter', () => Object.getOwnPropertyDescriptor(obj, 'p').get.toString());
T('obj-setter', () => Object.getOwnPropertyDescriptor(obj, 'p').set.toString());
T('obj-generator', () => obj.g2.toString());
T('obj-async', () => obj.a2.toString());
T('obj-fn-value', () => obj.fnValue.toString());
T('obj-arrow-value', () => obj.arrowValue.toString());

// --- exact text -------------------------------------------------------------
function multi(a,
               b) {
  // a comment inside
  const s = 'a } brace in a string';
  return a + b + s.length;
}
function tricky(a = ')', b = { x: '}' }) { return a + b.x; }
function spaced   (  a ,  b )   {   return a  ; }
function withRegex() { return /}\)/.test('x'); }

T('multi-line', () => multi.toString());
T('keeps-comments', () => multi.toString().includes('// a comment inside'));
T('brace-in-string', () => tricky.toString());
T('odd-spacing', () => spaced.toString());
T('regex-in-body', () => withRegex.toString());
T('trailing-newline-excluded', () => multi.toString().endsWith('}'));

// --- natives and bound ------------------------------------------------------
T('native', () => Math.max.toString());
T('native-array-method', () => Array.prototype.map.toString());
T('native-includes-marker', () => /\[native code\]/.test(Array.prototype.map.toString()));
T('native-ctor', () => Number.toString());
T('bound', () => decl.bind(null).toString());
T('bound-name-prop', () => decl.bind(null).name);
T('tostring-of-tostring', () => Function.prototype.toString.toString());

// --- the two idioms this exists for -----------------------------------------
T('parse-params', () => {
  const m = decl.toString().match(/\(([^)]*)\)/);
  return m ? m[1] : null;
});
T('detect-native', () => {
  const isNative = (f) => /\{\s*\[native code\]\s*\}/.test(Function.prototype.toString.call(f));
  return [isNative(Math.max), isNative(decl), isNative(arrow)].join(',');
});
T('detect-class', () => [/^class\s/.test(Klass.toString()), /^class\s/.test(decl.toString())].join(','));
T('detect-arrow', () => [/^\s*(\(|[A-Za-z_$])[^]*?=>/.test(arrow.toString()), /^function/.test(decl.toString())].join(','));

// --- coercions reach the same text ------------------------------------------
T('String-of', () => String(arrow));
T('template', () => `${arrowNoArg}`);
T('concat', () => '' + arrowBare);
T('join', () => [arrowNoArg].join(''));
T('stable', () => decl.toString() === decl.toString());

// --- wrong receivers --------------------------------------------------------
T('call-on-object', () => Function.prototype.toString.call({}));
T('call-on-number', () => Function.prototype.toString.call(5));
T('call-on-null', () => Function.prototype.toString.call(null));

// --- a function from a required module, read after the module finished ------
const mod = require('./modfix/fnsource.js');
T('required-fn', () => mod.helper.toString());
T('required-arrow', () => mod.inner.toString());
T('required-class-method', () => mod.Shape.prototype.area.toString());
T('required-after-gc', () => {
  // churn the heap first: the module's source has to outlive its load
  for (let i = 0; i < 2000; i++) { JSON.parse('{"a":[1,2,3]}'); }
  return mod.helper.toString();
});

console.log(rows.join('\n'));

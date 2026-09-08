// A destructuring pattern that stops early closes its iterator, whatever
// stopped it: exhaustion of the pattern, an element that throws, or a
// generator returned or thrown into while a pattern is suspended on a
// yield. A throw completion keeps its own error over one from return();
// otherwise a return() that answers with a non-object is a TypeError.
// An assignment target's reference is evaluated before the value is
// fetched.

const at = (f) => { try { return String(f()); } catch (e) { return e.constructor.name + (e.message && e.constructor.name !== 'TypeError' ? ': ' + e.message : ''); } };
const make = (opts) => {
  const log = [];
  const iterable = {
    [Symbol.iterator]() {
      return {
        next() { log.push('next'); return opts.next ? opts.next() : { value: undefined, done: false }; },
        return() { log.push('return'); if (opts.returnThrows) throw new RangeError('from return'); return opts.returnValue === undefined ? {} : opts.returnValue; },
      };
    },
  };
  return { iterable, log };
};

// normal completion with the pattern shorter than the source
let m = make({});
let a; [a] = m.iterable;
console.log('normal close:', m.log.join(','), a);
m = make({ returnValue: null });
console.log('normal close, non-object result:', at(() => { let b; [b] = m.iterable; return 'no throw'; }), m.log.join(','));

// an element target that throws before the step: reference first, then close
m = make({ returnThrows: true });
const thrower = () => { throw new SyntaxError('target'); };
console.log('target throws:', at(() => { [ ({})[thrower()] ] = m.iterable; }), m.log.join(','));

// a generator returned while a pattern waits on a yield
m = make({});
function* g1() { let x; [x = yield] = m.iterable; return 'finished ' + x; }
let it = g1();
it.next();
console.log('return into a suspended pattern:', JSON.stringify(it.return('r')), m.log.join(','));
m = make({ returnValue: null });
it = g1();
it.next();
console.log('return into a suspended pattern, non-object result:', at(() => it.return('r')), m.log.join(','));
m = make({ returnThrows: true });
it = g1();
it.next();
console.log('return into a suspended pattern, return() throws:', at(() => it.return('r')), m.log.join(','));

// a generator thrown into: the throw wins over the iterator's return()
m = make({ returnThrows: true });
it = g1();
it.next();
console.log('throw into a suspended pattern:', at(() => it.throw(new EvalError('thrown'))), m.log.join(','));

// the iterator is not closed once exhausted
m = make({ next: () => ({ done: true }) });
let c; [c] = m.iterable;
console.log('exhausted:', m.log.join(','), c);

// evaluation order of assignment targets: reference, then value
const order = [];
const obj = { set p(v) { order.push('set p=' + v); } };
const keyed = {};
[ (order.push('obj'), obj).p, (order.push('keyed'), keyed)[(order.push('key'), 'k')] = 'dflt' ] = { [Symbol.iterator]() { let n = 0; return { next() { order.push('next'); return n++ ? { done: true } : { value: 'v', done: false }; } }; } };
console.log('array order:', order.join(' '), keyed.k);
order.length = 0;
({ a: (order.push('obj'), obj).p, [(order.push('key'), 'b')]: (order.push('keyed'), keyed)[(order.push('k2'), 'b')] = 'd' } = { get a() { order.push('get a'); return 'A'; }, get b() { order.push('get b'); return undefined; } });
console.log('object order:', order.join(' '), keyed.b);

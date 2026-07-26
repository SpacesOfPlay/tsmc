// Array destructuring consumes its value through the iterator protocol, so
// every iterable works, iterator errors surface, and an unfinished iterator
// is closed.

const out = [];
const push = (label, v) => out.push(label + '=' + v);
const caught = (label, fn) => {
  try { fn(); out.push(label + '=no-throw'); }
  catch (e) { out.push(label + '=' + (e && e.tag ? e.tag : e.constructor.name)); }
};
const tagged = () => { const e = new Error('x'); e.tag = 'TAG'; return e; };

// --- iterables other than arrays -------------------------------------------
function* gen() { yield 1; yield 2; yield 3; }
{ const [a, b] = gen(); push('generator', a + ',' + b); }
{ const [a, b] = new Set([7, 8]); push('set', a + ',' + b); }
{ const [a] = new Map([[1, 'x']]); push('map', JSON.stringify(a)); }
{ const [a, b] = 'hi'; push('string', a + ',' + b); }
{ const [a, b] = [4, 5]; push('array', a + ',' + b); }
{
  const custom = { [Symbol.iterator]: () => { let i = 0; return { next: () => ({ value: i++, done: i > 3 }) }; } };
  const [a, b] = custom;
  push('custom', a + ',' + b);
}

// Rest, elision and defaults all step the same iterator.
{ const [a, ...r] = gen(); push('rest', a + '|' + JSON.stringify(r)); }
{ const [, b] = gen(); push('elision', b); }
{ const [, , , d = 'dflt'] = gen(); push('past-end-default', d); }
{ const [a, b, c, d] = gen(); push('past-end', d); }
{ const [...all] = gen(); push('rest-only', JSON.stringify(all)); }
{ const [a, [b, c]] = [1, gen()]; push('nested', a + ',' + b + ',' + c); }

// An array-like without Symbol.iterator is not destructurable.
caught('array-like', () => { const [a] = { length: 2, 0: 'p', 1: 'q' }; });

// --- errors propagate ------------------------------------------------------
const stepErr = { [Symbol.iterator]: () => ({ next() { throw tagged(); } }) };
caught('next-throws-decl', () => { const [x] = stepErr; });
caught('next-throws-param', () => { (([x]) => {})(stepErr); });
caught('next-throws-assign', () => { let x; [x] = stepErr; });

const poisonedValue = Object.defineProperty({}, 'value', { get() { throw tagged(); } });
const valErr = { [Symbol.iterator]: () => ({ next: () => poisonedValue }) };
caught('value-throws', () => { const [x] = valErr; });

caught('iterator-getter-throws', () => { const [x] = { get [Symbol.iterator]() { throw tagged(); } }; });
caught('next-not-callable', () => { const [x] = { [Symbol.iterator]: () => ({ next: 1 }) }; });
caught('not-iterable', () => { const [x] = {}; });
caught('null', () => { const [x] = null; });
caught('undefined', () => { const [x] = undefined; });

// The same guard applies to for-of and spread.
caught('for-of-null', () => { for (const x of null) { /* unreachable */ } });
caught('spread-null', () => { const a = [...null]; });

// --- the iterator is closed when the pattern stops early -------------------
function tracked() {
  const state = { closed: false, steps: 0 };
  state.iterable = {
    [Symbol.iterator]: () => ({
      next: () => { state.steps++; return { value: state.steps, done: false }; },
      return() { state.closed = true; return {}; },
    }),
  };
  return state;
}
{ const s = tracked(); const [a] = s.iterable; push('closed-early', s.closed + ',steps=' + s.steps); }
{ const s = tracked(); const [a, b] = s.iterable; push('closed-two', s.closed + ',steps=' + s.steps); }

// A finished iterator is not closed again, and a rest element exhausts it.
{
  let closed = false;
  const finite = { [Symbol.iterator]: () => { let i = 0; return { next: () => ({ value: i, done: i++ >= 2 }), return() { closed = true; return {}; } }; } };
  const [a, b, c] = finite;
  push('exhausted-not-closed', closed);
}
{
  let closed = false;
  const finite = { [Symbol.iterator]: () => { let i = 0; return { next: () => ({ value: i, done: i++ >= 2 }), return() { closed = true; return {}; } }; } };
  const [...all] = finite;
  push('rest-not-closed', closed + ',' + JSON.stringify(all));
}

console.log(out.join('\n'));

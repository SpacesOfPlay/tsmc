// The async iteration protocol in detail: a sync iterator used where an
// async one is expected has each value awaited, an async iterator's values
// are taken as they are, the next method is read once per loop, and a
// Symbol.asyncIterator that is not callable is a TypeError.

const kind = (v) => (v instanceof Promise ? 'a promise' : String(v));

const seen = [];
for await (const v of [Promise.resolve('p1'), 'plain']) seen.push(v);
console.log('for await over a sync iterable:', seen.join(','));

const asyncIt = {
  [Symbol.asyncIterator]() {
    let n = 0;
    return { next() { n++; return Promise.resolve(n === 1 ? { value: Promise.resolve('inner'), done: false } : { done: true }); } };
  },
};
for await (const v of asyncIt) console.log('for await over an async iterator:', kind(v));

async function* viaSync() { const r = yield* [Promise.resolve('sync delegate value')]; return r; }
async function* viaAsync() { yield* asyncIt; }
for await (const v of viaSync()) console.log('yield* over a sync iterable:', kind(v));
for await (const v of viaAsync()) console.log('yield* over an async iterator:', kind(v));

// next is read once, then called with the sent value (a plain for-of still
// reads it per step, which is not covered here)
const log = [];
const logged = {
  [Symbol.iterator]() {
    let n = 0;
    return {
      get next() { log.push('get next'); return function (sent) { log.push('call next(' + sent + ')'); n++; return n < 3 ? { value: n, done: false } : { value: 'end', done: true }; }; },
    };
  },
};
function* syncOuter() { const r = yield* logged; log.push('result ' + r); }
const it = syncOuter();
it.next('first'); it.next('second'); it.next('third');
console.log('sync yield* log:', log.join(' | '));
log.length = 0;
async function* asyncOuter() { const r = yield* logged; log.push('result ' + r); }
const ait = asyncOuter();
await ait.next('first'); await ait.next('second'); await ait.next('third');
console.log('async yield* log:', log.join(' | '));
log.length = 0;
for await (const v of logged) log.push('saw ' + v);
console.log('for await log:', log.join(' | '));

// a present but non-callable Symbol.asyncIterator
const notCallable = { [Symbol.asyncIterator]: 42, [Symbol.iterator]() { return [1][Symbol.iterator](); } };
try { for await (const v of notCallable) {} console.log('no throw'); } catch (e) { console.log('for await, non-callable:', e.constructor.name); }
async function* overNotCallable() { try { yield* notCallable; } catch (e) { yield 'caught ' + e.constructor.name; } }
for await (const v of overNotCallable()) console.log('yield*, non-callable:', v);
const nullish = { [Symbol.asyncIterator]: null, [Symbol.iterator]() { return ['sync fallback'][Symbol.iterator](); } };
for await (const v of nullish) console.log('null Symbol.asyncIterator falls back:', v);

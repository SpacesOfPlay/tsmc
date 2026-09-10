// A promise resolved with a thenable reads its `then` once, and calls that
// same function in a later tick. `await` goes through the same path, so an
// await, a yield in an async generator and Promise.resolve all read it once.

const log = [];
const mk = (v, reject) => ({
  get then() {
    log.push('get then');
    return function (res, rej) {
      log.push('call then, this is the thenable: ' + (this === mk_last));
      (reject ? rej : res)(v);
    };
  },
});
let mk_last;
const thenable = (v, reject) => { mk_last = mk(v, reject); return mk_last; };

const show = (label) => { console.log(label, JSON.stringify(log)); log.length = 0; };

(async () => {
  await thenable(1);
  show('await:');

  await Promise.resolve(thenable(2));
  show('Promise.resolve:');

  await new Promise((res) => res(thenable(3)));
  show('resolve inside the executor:');

  try { await thenable(4, true); } catch (e) { log.push('caught ' + e); }
  show('a rejecting thenable:');

  // an object with no callable `then` is not a thenable: fulfilled as it is
  const plain = { then: 1 };
  console.log('not callable:', (await plain) === plain);

  // a `then` getter that throws rejects instead
  const bad = { get then() { log.push('get then'); throw new RangeError('no'); } };
  try { await bad; } catch (e) { log.push('caught ' + e.constructor.name); }
  show('a throwing getter:');

  // an async generator awaits its yielded value the same way
  async function* g() { yield thenable(5); yield 6; }
  const it = g();
  console.log('yield:', JSON.stringify(await it.next()));
  show('yield in an async generator:');

  // and so does yield* over an async iterator whose results are thenables
  const src = {
    [Symbol.asyncIterator]() {
      let n = 0;
      return { next() { n++; return thenable({ value: n, done: n > 2 }); } };
    },
  };
  async function* h() { const last = yield* src; return 'done ' + last; }
  const hi = h();
  console.log('yield* 1:', JSON.stringify(await hi.next()));
  console.log('yield* 2:', JSON.stringify(await hi.next()));
  console.log('yield* 3:', JSON.stringify(await hi.next()));
  show('yield* over thenable results:');

  // the ticks a thenable costs, against a plain value and a native promise
  const order = [];
  Promise.resolve().then(() => order.push('t1')).then(() => order.push('t2'))
    .then(() => order.push('t3')).then(() => order.push('t4'));
  (async () => { await { then(r) { r(); } }; order.push('thenable await'); })();
  (async () => { await 1; order.push('plain await'); })();
  (async () => { await Promise.resolve(); order.push('promise await'); })();
  await Promise.resolve().then().then().then().then().then();
  console.log('order:', order.join(','));
})();

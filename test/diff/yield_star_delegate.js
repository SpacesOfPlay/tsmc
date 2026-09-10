// What `yield*` does to the iterator it delegates to: which methods it
// looks up and how often, what it calls them on, and what it does with the
// result. `next` is read once for the whole delegation; `return` and
// `throw` are read once each time one is needed, and a value that is
// neither undefined nor callable is an error rather than an absence.
//
// Only the error's kind is printed, since runtimes word the message
// differently.

const log = [];
const L = (...a) => log.push(a.join(' '));

function watched(tag, kind) {
  let n = 0;
  const iter = {
    get next() {
      L(tag, 'get next');
      return function (v) {
        L(tag, 'call next', JSON.stringify(v), 'this===iter:' + (this === iter));
        n++;
        const r = {
          get value() { L(tag, 'get next.value'); return tag + n; },
          get done() { L(tag, 'get next.done'); return n > 2; },
        };
        return kind === 'async' ? Promise.resolve(r) : r;
      };
    },
    get return() {
      L(tag, 'get return');
      return function (v) {
        L(tag, 'call return', JSON.stringify(v), 'this===iter:' + (this === iter));
        const r = { value: tag + '-ret', done: true };
        return kind === 'async' ? Promise.resolve(r) : r;
      };
    },
    get throw() {
      L(tag, 'get throw');
      return function (v) {
        L(tag, 'call throw', String(v && v.message), 'this===iter:' + (this === iter));
        const r = { value: tag + '-caught', done: true };
        return kind === 'async' ? Promise.resolve(r) : r;
      };
    },
  };
  const key = kind === 'async' ? Symbol.asyncIterator : Symbol.iterator;
  return { [key]() { L(tag, 'get iterator'); return iter; } };
}

const plain = (key, methods) => ({ [key]() { return methods; } });
const step = (v, d) => ({ value: v, done: d });

async function drive(name, makeGen, steps) {
  L('--', name);
  const g = makeGen();
  for (const s of steps) {
    try {
      const r = await (s[0] === 'next' ? g.next(s[1]) : s[0] === 'return' ? g.return(s[1]) : g.throw(s[1]));
      L(s[0], '->', JSON.stringify(r.value), String(r.done));
    } catch (e) {
      L(s[0], 'threw', e.constructor.name);
    }
  }
}

(async () => {
  for (const kind of ['sync', 'async']) {
    await drive(kind + ': to completion',
      async function* () { const r = yield* watched(kind[0], kind); L('result', JSON.stringify(r)); },
      [['next'], ['next', 'a'], ['next', 'b'], ['next']]);
    await drive(kind + ': return partway',
      async function* () { yield* watched(kind[0], kind); },
      [['next'], ['return', 'bye']]);
    await drive(kind + ': throw partway',
      async function* () { yield* watched(kind[0], kind); },
      [['next'], ['throw', new Error('boom')]]);
  }

  // a sync generator delegating to a sync iterator. Its results are the
  // delegate's own objects, so this one reads plain properties: a getter
  // here would be counting the consumer's reads too.
  await drive('sync generator, sync delegate',
    function* () {
      let n = 0;
      yield* plain(Symbol.iterator, {
        next: () => (n++ < 2 ? step('s' + n, false) : step('done', true)),
        return: (v) => { L('sync return', JSON.stringify(v)); return step('closed', true); },
      });
    },
    [['next'], ['next'], ['return', 'bye']]);

  // present but not callable is a protocol violation, not an absence
  await drive('throw is a number',
    async function* () { yield* plain(Symbol.iterator, { next: () => step('v', false), throw: 42 }); },
    [['next'], ['throw', new Error('boom')]]);
  await drive('return is a number',
    async function* () { yield* plain(Symbol.iterator, { next: () => step('v', false), return: 42 }); },
    [['next'], ['return', 'bye']]);

  // a result that is not an object, and a delegate that rejects
  await drive('next returns a non-object',
    async function* () { yield* plain(Symbol.iterator, { next: () => 'not an object' }); },
    [['next']]);
  await drive('async next rejects',
    async function* () { yield* plain(Symbol.asyncIterator, { next: () => Promise.reject(new RangeError('no')) }); },
    [['next']]);

  // a sync delegate's values are awaited by an async generator
  await drive('sync delegate yielding promises',
    async function* () {
      let n = 0;
      yield* plain(Symbol.iterator, { next: () => (n++ < 2 ? step(Promise.resolve('p' + n), false) : step('end', true)) });
    },
    [['next'], ['next'], ['next']]);

  // a string delegates by its own iterator
  await drive('delegate is a string',
    async function* () { yield* 'ab'; },
    [['next'], ['next'], ['next']]);

  console.log(log.join('\n'));
})();

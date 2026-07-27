// Execution ordering: the sync phase, then microtasks, then timers, and how
// many ticks each await-ish construct costs. Independent .then chains act as a
// tick ruler — anything landing between t2 and t3 took three turns to settle.
// Everything logs into one array printed from a final timer.

const log = [];
const L = (s) => log.push(s);

// Sync phase runs to completion before any microtask.
L('sync-start');
setTimeout(() => L('timer0'), 0);
Promise.resolve().then(() => L('micro1'));
queueMicrotask(() => L('micro2'));
L('sync-end');

// Two independent chains step in lockstep, one link per turn.
Promise.resolve().then(() => L('A1')).then(() => L('A2')).then(() => L('A3'));
Promise.resolve().then(() => L('B1')).then(() => L('B2')).then(() => L('B3'));

// An async function body runs synchronously up to its first await.
(async () => {
  L('async-fn-sync-part');
  await null;
  L('after-await-null');
  await Promise.resolve();
  L('after-await-promise');
})();

// Resolving with a promise costs the extra thenable-job turn.
Promise.resolve().then(() => L('t1')).then(() => L('t2')).then(() => L('t3')).then(() => L('t4'));
new Promise((res) => res(Promise.resolve())).then(() => L('resolve-with-promise'));

// A plain thenable is assimilated the same way.
Promise.resolve().then(() => L('u1')).then(() => L('u2')).then(() => L('u3'));
Promise.resolve({ then: (r) => r('x') }).then(() => L('thenable'));

// So is an async function that returns a promise.
(async () => Promise.resolve())().then(() => L('async-returns-promise'));
Promise.resolve().then(() => L('v1')).then(() => L('v2')).then(() => L('v3')).then(() => L('v4'));

// Same-deadline timers fire in registration order: 0ms clamps up to 1ms, so
// the 1ms timer registered first still goes first.
setTimeout(() => L('timerB'), 1);
setTimeout(() => L('timerA'), 0);

// Microtasks queued by a timer drain before the next timer runs.
setTimeout(() => {
  L('timer-outer');
  Promise.resolve().then(() => L('micro-in-timer'));
}, 5);
setTimeout(() => L('timer-after'), 6);

// A rejection handled by .catch keeps its place in the queue.
Promise.reject(new Error('x')).catch(() => L('caught')).then(() => L('after-catch'));

// Each loop iteration's await costs one turn.
(async () => {
  for (const i of [1, 2]) {
    await i;
    L('loop-await-' + i);
  }
})();

setTimeout(() => {
  console.log(log.join('\n'));
}, 50);

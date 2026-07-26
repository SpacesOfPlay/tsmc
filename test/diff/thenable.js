// Any object with a callable `then` is assimilated wherever a promise is
// resolved — await, Promise.resolve, the resolve function, and the
// combinators — rather than being passed through as a plain value. The call
// happens in a job, so the extra tick matches the specified ordering.

const log = [];
const p = (s) => log.push(s);

const thenable = (v) => ({ then(res) { res(v); } });
const rejecting = (m) => ({ then(res, rej) { rej(new Error(m)); } });

(async () => {
  p('await=' + (await thenable(42)));
  p('await-nested=' + (await { then(r) { r(thenable('deep')); } }));
  p('await-plain=' + JSON.stringify(await { a: 1 }));
  p('await-not-callable=' + JSON.stringify(await { then: 5 }));
  p('await-number=' + (await 5));
  p('await-promise=' + (await Promise.resolve(7)));

  try { await rejecting('r'); p('await-reject=no-throw'); }
  catch (e) { p('await-reject=' + e.message); }

  try { await { then() { throw new Error('t'); } }; p('then-throws=no-throw'); }
  catch (e) { p('then-throws=' + e.message); }

  // A throwing `then` getter rejects the awaited value, so the awaiting
  // function's own catch still sees it.
  try { await { get then() { throw new Error('g'); } }; p('getter-throws=no-throw'); }
  catch (e) { p('getter-throws=' + e.message); }

  // Resolving only counts once.
  p('resolve-twice=' + (await { then(r) { r(1); r(2); } }));

  // The same assimilation through the Promise entry points.
  p('Promise.resolve=' + (await Promise.resolve(thenable('pr'))));
  p('resolve-fn=' + (await new Promise((res) => res(thenable('rf')))));
  p('all=' + JSON.stringify(await Promise.all([thenable(1), 2])));
  p('race=' + (await Promise.race([thenable('first'), new Promise(() => {})])));
  p('allSettled=' + (await Promise.allSettled([thenable(1), rejecting('x')])).map((s) => s.status).join(','));
  p('any=' + (await Promise.any([rejecting('a'), thenable('b')])));

  // A thenable resolved through catch/finally.
  p('catch=' + (await Promise.reject(new Error('c')).catch(() => thenable('recovered'))));

  // Ordering: a thenable takes one more tick than a plain promise.
  const order = [];
  Promise.resolve('plain').then(() => order.push('plain'));
  Promise.resolve(thenable('t')).then(() => order.push('thenable'));
  await null;
  await null;
  await null;
  p('ordering=' + order.join(','));

  // Many in sequence, to exercise the job queue.
  let sum = 0;
  for (let i = 0; i < 50; i++) { sum += await thenable(i); }
  p('loop-sum=' + sum);

  console.log(log.join('\n'));
})();

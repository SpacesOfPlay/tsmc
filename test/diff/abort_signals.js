// What actually honours an AbortSignal handed to it: timers/promises,
// events.once, fs.promises and fetch.
//
// The reasons differ by API and that is node's doing, not an accident here.
// timers and events always reject with a fresh AbortError, whatever the
// signal was aborted with; fetch rejects with the signal's own reason, so a
// string stays a string. Both are checked below.
//
// The server listens on port 0 and nothing prints a port, so the output is
// stable.

const timers = require('timers/promises');
const events = require('events');
const fsp = require('fs/promises');
const http = require('http');

const out = [];
const say = (l, v) => out.push(l + ' = ' + v);
const nameOf = (e) => (typeof e === 'string' ? 'string:' + e : (e && e.name ? e.name : String(e)));
const detail = (e) => (typeof e === 'string' ? 'string:' + e : e.name + '/' + e.message);

async function main() {
  // --- timers/promises ------------------------------------------------------
  try {
    await timers.setTimeout(5, 'v', { signal: AbortSignal.abort() });
    say('timers-pre-aborted', 'resolved');
  } catch (e) { say('timers-pre-aborted', 'rejected:' + detail(e)); }

  try {
    const c = new AbortController();
    setTimeout(() => c.abort(), 5);
    await timers.setTimeout(2000, 'v', { signal: c.signal });
    say('timers-abort-midway', 'resolved');
  } catch (e) { say('timers-abort-midway', 'rejected:' + nameOf(e)); }

  try {
    await timers.setTimeout(5, 'v', { signal: AbortSignal.abort('custom') });
    say('timers-ignores-custom-reason', 'resolved');
  } catch (e) { say('timers-ignores-custom-reason', 'rejected:' + detail(e)); }

  try {
    const v = await timers.setTimeout(1, 'ok', { signal: new AbortController().signal });
    say('timers-not-aborted', 'resolved:' + v);
  } catch (e) { say('timers-not-aborted', 'rejected:' + nameOf(e)); }

  try {
    const v = await timers.setTimeout(1, 'plain');
    say('timers-no-options', 'resolved:' + v);
  } catch (e) { say('timers-no-options', 'rejected:' + nameOf(e)); }

  try {
    const v = await timers.setImmediate('now', { signal: new AbortController().signal });
    say('timers-immediate', 'resolved:' + v);
  } catch (e) { say('timers-immediate', 'rejected:' + nameOf(e)); }

  // --- events.once ----------------------------------------------------------
  try {
    const em = new events.EventEmitter();
    setTimeout(() => em.emit('go', 1, 2), 1);
    const v = await events.once(em, 'go');
    say('once-resolves-args', JSON.stringify(v));
  } catch (e) { say('once-resolves-args', 'rejected:' + nameOf(e)); }

  try {
    const em = new events.EventEmitter();
    await events.once(em, 'never', { signal: AbortSignal.abort() });
    say('once-pre-aborted', 'resolved');
  } catch (e) { say('once-pre-aborted', 'rejected:' + detail(e)); }

  try {
    const em = new events.EventEmitter();
    const c = new AbortController();
    setTimeout(() => c.abort('whatever'), 5);
    await events.once(em, 'never', { signal: c.signal });
    say('once-abort-midway', 'resolved');
  } catch (e) { say('once-abort-midway', 'rejected:' + detail(e)); }

  try {
    const em = new events.EventEmitter();
    setTimeout(() => em.emit('error', new RangeError('bad')), 1);
    await events.once(em, 'go');
    say('once-error-event', 'resolved');
  } catch (e) { say('once-error-event', 'rejected:' + detail(e)); }

  try {
    const em = new events.EventEmitter();
    setTimeout(() => em.emit('error', new RangeError('bad')), 1);
    const v = await events.once(em, 'error');
    say('once-awaiting-error', 'resolved:' + v[0].name);
  } catch (e) { say('once-awaiting-error', 'rejected:' + nameOf(e)); }

  {
    const em = new events.EventEmitter();
    const c = new AbortController();
    const p = events.once(em, 'x', { signal: c.signal }).catch(() => {});
    const before = em.listenerCount('x');
    c.abort();
    await p;
    say('once-removes-listener', 'before:' + before + ' after:' + em.listenerCount('x'));
  }

  {
    const em = new events.EventEmitter();
    const p = events.once(em, 'go');
    em.emit('go', 'v');
    await p;
    say('once-removes-after-fire', String(em.listenerCount('go')));
  }

  // --- fs.promises ----------------------------------------------------------
  try {
    await fsp.readFile(__filename, { signal: AbortSignal.abort() });
    say('fs-pre-aborted', 'resolved');
  } catch (e) { say('fs-pre-aborted', 'rejected:' + e.name + '/' + e.code); }

  try {
    const text = await fsp.readFile(__filename, { encoding: 'utf8', signal: new AbortController().signal });
    say('fs-live-signal', 'resolved:' + (text.length > 0));
  } catch (e) { say('fs-live-signal', 'rejected:' + nameOf(e)); }

  try {
    await fsp.stat(__filename + '.nope', { signal: AbortSignal.abort() });
    say('fs-abort-beats-enoent', 'resolved');
  } catch (e) { say('fs-abort-beats-enoent', 'rejected:' + e.name); }

  // --- fetch ----------------------------------------------------------------
  const server = http.createServer((req, res) => {
    if (req.url === '/slow') {
      setTimeout(() => { res.end('late'); }, 300);
      return;
    }
    res.end('quick');
  });
  await new Promise((r) => server.listen(0, r));
  const base = 'http://127.0.0.1:' + server.address().port;

  try {
    await fetch(base + '/quick', { signal: AbortSignal.abort() });
    say('fetch-pre-aborted', 'resolved');
  } catch (e) { say('fetch-pre-aborted', 'rejected:' + detail(e)); }

  try {
    await fetch(base + '/quick', { signal: AbortSignal.abort('custom reason') });
    say('fetch-forwards-reason', 'resolved');
  } catch (e) { say('fetch-forwards-reason', 'rejected:' + nameOf(e)); }

  try {
    const r = await fetch(base + '/quick', { signal: new AbortController().signal });
    say('fetch-not-aborted', 'resolved:' + (await r.text()));
  } catch (e) { say('fetch-not-aborted', 'rejected:' + nameOf(e)); }

  try {
    const c = new AbortController();
    setTimeout(() => c.abort(), 20);
    const r = await fetch(base + '/slow', { signal: c.signal });
    await r.text();
    say('fetch-abort-midway', 'resolved');
  } catch (e) { say('fetch-abort-midway', 'rejected:' + detail(e)); }

  try {
    const r = await fetch(base + '/quick', { signal: AbortSignal.timeout(5000) });
    say('fetch-timeout-signal-unused', 'resolved:' + (await r.text()));
  } catch (e) { say('fetch-timeout-signal-unused', 'rejected:' + nameOf(e)); }

  try {
    const c = new AbortController();
    const r = await fetch(base + '/quick', { signal: c.signal });
    const body = await r.text();
    c.abort();
    say('fetch-abort-after-done', 'resolved:' + body);
  } catch (e) { say('fetch-abort-after-done', 'rejected:' + nameOf(e)); }

  server.close();
  console.log(out.join('\n'));
}

main();

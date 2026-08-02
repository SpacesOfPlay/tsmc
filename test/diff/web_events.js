// EventTarget, Event, CustomEvent, AbortController/AbortSignal, DOMException
// and performance.
//
// Nothing here prints a duration, only whether one number follows another, so
// the output is stable.
//
// Two gaps are deliberate. `performance` carries now() and timeOrigin, not the
// entry-buffer API, and atob/btoa still report a plain Error whose name is
// InvalidCharacterError rather than a DOMException, so only the name is
// checked below.
//
// One difference is deliberate the other way. node's removeEventListener
// ignores the boolean capture argument that addEventListener accepts, so
// removeEventListener(type, fn, true) does not undo addEventListener(type, fn,
// true) there. tsmc honours the boolean on both, since silently failing to
// remove a listener is the worse of the two behaviours. The capture cases
// below use the options-object form, which both agree on.
const rows = [];
function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.join(',') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.name ? e.name : String(e)); }
  rows.push(label + ' = ' + show(v));
}

// --- DOMException -----------------------------------------------------------
T('dex-type', () => typeof DOMException);
T('dex-fields', () => { const e = new DOMException('m', 'AbortError'); return [e.name, e.message, e.code].join(','); });
T('dex-default-name', () => { const e = new DOMException('m'); return [e.name, e.code].join(','); });
T('dex-no-args', () => { const e = new DOMException(); return [e.name, JSON.stringify(e.message), e.code].join(','); });
T('dex-is-error', () => { const e = new DOMException('m', 'AbortError'); return [e instanceof Error, e instanceof DOMException].join(','); });
T('dex-tostring', () => String(new DOMException('boom', 'NotFoundError')));
T('dex-tag', () => Object.prototype.toString.call(new DOMException('m')));
T('dex-codes', () => ['IndexSizeError', 'InvalidCharacterError', 'NotFoundError', 'TimeoutError', 'AbortError', 'NopeError']
  .map((n) => new DOMException('m', n).code).join(','));
T('dex-constant', () => [DOMException.ABORT_ERR, DOMException.TIMEOUT_ERR].join(','));
T('dex-has-stack', () => typeof new DOMException('m').stack);
T('dex-message-enumerable', () => Object.keys(new DOMException('m', 'AbortError')).join(','));

// --- Event / CustomEvent ----------------------------------------------------
T('event-type', () => new Event('x').type);
T('event-defaults', () => { const e = new Event('x'); return [e.bubbles, e.cancelable, e.defaultPrevented, e.target, e.eventPhase].join(','); });
T('event-no-type', () => new Event());
T('event-cancelable', () => { const e = new Event('x', { cancelable: true }); e.preventDefault(); return e.defaultPrevented; });
T('event-not-cancelable', () => { const e = new Event('x'); e.preventDefault(); return e.defaultPrevented; });
T('event-tag', () => Object.prototype.toString.call(new Event('x')));
T('custom-detail', () => new CustomEvent('x', { detail: { a: 1 } }).detail);
T('custom-detail-default', () => new CustomEvent('x').detail);
T('custom-is-event', () => new CustomEvent('x') instanceof Event);

// --- EventTarget ------------------------------------------------------------
T('et-basic', () => {
  const t = new EventTarget();
  const seen = [];
  t.addEventListener('ping', (e) => seen.push(e.type));
  t.dispatchEvent(new Event('ping'));
  return seen.join(',');
});
T('et-target-set', () => {
  const t = new EventTarget();
  let got = null;
  t.addEventListener('p', (e) => { got = e.target === t; });
  t.dispatchEvent(new Event('p'));
  return got;
});
T('et-dispatch-returns', () => new EventTarget().dispatchEvent(new Event('p')));
T('et-dispatch-prevented', () => {
  const t = new EventTarget();
  t.addEventListener('p', (e) => e.preventDefault());
  return t.dispatchEvent(new Event('p', { cancelable: true }));
});
T('et-order', () => {
  const t = new EventTarget();
  const seen = [];
  t.addEventListener('p', () => seen.push(1));
  t.addEventListener('p', () => seen.push(2));
  t.dispatchEvent(new Event('p'));
  return seen.join(',');
});
T('et-duplicate-ignored', () => {
  const t = new EventTarget();
  let n = 0;
  const f = () => n++;
  t.addEventListener('p', f);
  t.addEventListener('p', f);
  t.dispatchEvent(new Event('p'));
  return n;
});
T('et-remove', () => {
  const t = new EventTarget();
  let n = 0;
  const f = () => n++;
  t.addEventListener('p', f);
  t.removeEventListener('p', f);
  t.dispatchEvent(new Event('p'));
  return n;
});
T('et-once', () => {
  const t = new EventTarget();
  let n = 0;
  t.addEventListener('p', () => n++, { once: true });
  t.dispatchEvent(new Event('p'));
  t.dispatchEvent(new Event('p'));
  return n;
});
T('et-handle-event-object', () => {
  const t = new EventTarget();
  let n = 0;
  t.addEventListener('p', { handleEvent() { n++; } });
  t.dispatchEvent(new Event('p'));
  return n;
});
T('et-remove-during-dispatch', () => {
  const t = new EventTarget();
  const seen = [];
  const b = () => seen.push('b');
  t.addEventListener('p', () => { seen.push('a'); t.removeEventListener('p', b); });
  t.addEventListener('p', b);
  t.dispatchEvent(new Event('p'));
  return seen.join(',');
});
T('et-bad-event', () => new EventTarget().dispatchEvent('p'));
T('et-tag', () => Object.prototype.toString.call(new EventTarget()));
T('et-signal-option', () => {
  const t = new EventTarget();
  const c = new AbortController();
  let n = 0;
  t.addEventListener('p', () => n++, { signal: c.signal });
  t.dispatchEvent(new Event('p'));
  c.abort();
  t.dispatchEvent(new Event('p'));
  return n;
});

// --- AbortController / AbortSignal ------------------------------------------
T('ac-shape', () => { const c = new AbortController(); return [typeof c.abort, c.signal.aborted, c.signal.reason].join(','); });
T('ac-abort', () => { const c = new AbortController(); c.abort(); return c.signal.aborted; });
T('ac-reason-default', () => { const c = new AbortController(); c.abort(); return [c.signal.reason.name, c.signal.reason.message].join('|'); });
T('ac-reason-custom', () => { const c = new AbortController(); c.abort('why'); return c.signal.reason; });
T('ac-event', () => {
  const c = new AbortController();
  const seen = [];
  c.signal.addEventListener('abort', (e) => seen.push(e.type));
  c.abort();
  c.abort();
  return seen.join(',');
});
T('ac-onabort', () => {
  const c = new AbortController();
  let n = 0;
  c.signal.onabort = () => n++;
  c.abort();
  return n;
});
T('ac-throw-if-aborted', () => {
  const c = new AbortController();
  c.signal.throwIfAborted();
  c.abort('stop');
  try { c.signal.throwIfAborted(); return 'no throw'; } catch (e) { return e; }
});
T('ac-signal-is-target', () => new AbortController().signal instanceof EventTarget);
T('ac-signal-tag', () => Object.prototype.toString.call(new AbortController().signal));
T('as-construct-directly', () => new AbortSignal());
T('as-static-abort', () => { const s = AbortSignal.abort(); return [s.aborted, s.reason.name].join(','); });
T('as-static-abort-reason', () => AbortSignal.abort('r').reason);
T('as-any-shape', () => typeof AbortSignal.any);
T('as-any-already', () => {
  const s = AbortSignal.any([AbortSignal.abort('first'), new AbortController().signal]);
  return [s.aborted, s.reason].join(',');
});
T('as-any-later', () => {
  const c = new AbortController();
  const s = AbortSignal.any([new AbortController().signal, c.signal]);
  const before = s.aborted;
  c.abort('late');
  return [before, s.aborted, s.reason].join(',');
});
T('as-timeout-shape', () => { const s = AbortSignal.timeout(5); return [s.aborted, s instanceof AbortSignal].join(','); });

T('as-any-empty', () => AbortSignal.any([]).aborted);
T('ac-abort-undefined-reason', () => { const c = new AbortController(); c.abort(undefined); return c.signal.reason.name; });
T('ac-signal-stable', () => { const c = new AbortController(); return c.signal === c.signal; });

// --- subclassing and the globals themselves ---------------------------------
T('et-subclass', () => {
  class Bus extends EventTarget {
    send(v) { this.dispatchEvent(new CustomEvent('msg', { detail: v })); }
  }
  const b = new Bus();
  let got = null;
  b.addEventListener('msg', (e) => { got = e.detail; });
  b.send(7);
  return got;
});
T('et-capture-pairs', () => {
  const t = new EventTarget();
  let n = 0;
  const f = () => n++;
  t.addEventListener('p', f, { capture: true });
  t.removeEventListener('p', f, { capture: true });
  t.dispatchEvent(new Event('p'));
  return n;
});
T('et-capture-distinguishes', () => {
  const t = new EventTarget();
  let n = 0;
  const f = () => n++;
  t.addEventListener('p', f, { capture: true });
  t.addEventListener('p', f, { capture: false });
  t.dispatchEvent(new Event('p'));
  return n;
});
T('et-capture-mismatch-keeps', () => {
  const t = new EventTarget();
  let n = 0;
  const f = () => n++;
  t.addEventListener('p', f, { capture: true });
  t.removeEventListener('p', f);
  t.dispatchEvent(new Event('p'));
  return n;
});
T('et-unknown-type', () => {
  const t = new EventTarget();
  t.addEventListener('a', () => {});
  return t.dispatchEvent(new Event('b'));
});
T('globalThis-identity', () => [
  globalThis.AbortController === AbortController,
  globalThis.EventTarget === EventTarget,
].join(','));
T('atob-error-name', () => { try { atob('!!'); return 'no throw'; } catch (e) { return e.name; } });

// --- performance ------------------------------------------------------------
T('perf-now-type', () => typeof performance.now());
T('perf-monotonic', () => { const a = performance.now(); let x = 0; for (let i = 0; i < 100000; i++) x += i; return performance.now() >= a; });
T('perf-origin-type', () => typeof performance.timeOrigin);
T('perf-origin-recent', () => Math.abs(Date.now() - (performance.timeOrigin + performance.now())) < 5000);
T('perf-hooks-same', () => require('perf_hooks').performance === performance);
T('perf-hooks-node-prefix', () => require('node:perf_hooks').performance === performance);
T('perf-now-advances', () => {
  const a = performance.now();
  let x = 0;
  for (let i = 0; i < 500000; i++) x += i;
  return performance.now() > a;
});
T('process-uptime-small', () => process.uptime() < 300);

// --- the asynchronous parts -------------------------------------------------
async function tail() {
  const out = [];
  // AbortSignal.timeout does not hold the event loop open on its own
  const keepAlive = setTimeout(() => {}, 200);
  const timedOut = await new Promise((resolve) => {
    const s = AbortSignal.timeout(10);
    s.addEventListener('abort', () => resolve([s.aborted, s.reason.name].join(',')));
  });
  out.push('timeout-fires = ' + timedOut);

  const anyLater = await new Promise((resolve) => {
    const c = new AbortController();
    const s = AbortSignal.any([c.signal]);
    s.addEventListener('abort', () => resolve(s.reason));
    setTimeout(() => c.abort('after a tick'), 1);
  });
  out.push('any-forwards = ' + JSON.stringify(anyLater));

  console.log(rows.join('\n'));
  console.log(out.join('\n'));
}
tail();

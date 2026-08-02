// process as an EventEmitter: exit, beforeExit, uncaughtException,
// unhandledRejection and warning.
//
// This script has to leave with status 0, since the gc-stress pass runs every
// diff script and only accepts a clean exit. The exit statuses those events
// produce are checked by the CLI smoke tests instead (test/cli/exitcode.js).
//
// process.emitWarning prints to stderr when nothing is listening, and that
// line carries a pid, so every case below installs a listener first.

const out = [];
const say = (l, v) => out.push(l + ' = ' + v);

// --- it is an emitter -------------------------------------------------------
say('has-on', [typeof process.on, typeof process.emit, typeof process.removeAllListeners].join(','));
say('listener-count-empty', process.listenerCount('nothing'));
{
  const seen = [];
  const f = (v) => seen.push('a' + v);
  process.on('custom', f);
  process.once('custom', (v) => seen.push('b' + v));
  process.emit('custom', 1);
  process.emit('custom', 2);
  process.off('custom', f);
  process.emit('custom', 3);
  say('custom-event', seen.join(',') + ' count=' + process.listenerCount('custom'));
}

// --- warning ----------------------------------------------------------------
{
  const seen = [];
  process.removeAllListeners('warning');
  process.on('warning', (w) => seen.push([w.name, w.message, w.code].join('|')));
  process.emitWarning('careful', 'MyWarning', 'W001');
  process.emitWarning(new RangeError('as error'));
  process.emitWarning('typed', { type: 'Custom', code: 'C1' });
  process.emitWarning('bare');
  say('warnings', JSON.stringify(seen));
  say('warning-is-error', (() => {
    let ok = false;
    process.removeAllListeners('warning');
    process.on('warning', (w) => { ok = w instanceof Error && typeof w.stack === 'string'; });
    process.emitWarning('shape');
    return ok;
  })());
  process.removeAllListeners('warning');
}

// --- uncaughtException ------------------------------------------------------
{
  const seen = [];
  process.on('uncaughtException', (e) => seen.push(e.message));
  setTimeout(() => { throw new Error('from a timer'); }, 1);
  setTimeout(() => {
    say('uncaught-caught', JSON.stringify(seen));
    say('uncaught-kept-running', true);
    process.removeAllListeners('uncaughtException');
    stage2();
  }, 5);
}

// --- unhandledRejection -----------------------------------------------------
function stage2() {
  const seen = [];
  process.on('unhandledRejection', (reason, p) => {
    seen.push(reason.message + '/' + (p instanceof Promise));
  });
  Promise.reject(new Error('nobody catches this'));
  setTimeout(() => {
    say('unhandled-rejection', JSON.stringify(seen));
    process.removeAllListeners('unhandledRejection');
    stage3();
  }, 5);
}

// --- a rejection that IS handled never reaches the listener ------------------
function stage3() {
  const seen = [];
  process.on('unhandledRejection', (reason) => seen.push(reason.message));
  const p = Promise.reject(new Error('but this one is caught'));
  p.catch(() => {});
  setTimeout(() => {
    say('handled-rejection-silent', JSON.stringify(seen));
    process.removeAllListeners('unhandledRejection');
    stage4();
  }, 5);
}

// --- beforeExit and exit ----------------------------------------------------
function stage4() {
  let scheduled = false;
  process.on('beforeExit', (code) => {
    out.push('beforeExit = code:' + code);
    if (!scheduled) {
      // work scheduled from beforeExit runs, and the loop asks again
      scheduled = true;
      setTimeout(() => out.push('work-from-beforeExit = ran'), 1);
    }
  });
  process.on('exit', (code) => {
    out.push('exit = code:' + code);
    console.log(out.join('\n'));
  });
  say('stages-done', true);
}

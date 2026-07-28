// EventEmitter: registration, ordering, removal during emit, the 'error'
// contract, the meta events, and the introspection methods.
//
// One check here is about the language rather than the module:
// arrow-this-not-emitter. emit() calls listeners with the emitter as the
// receiver, and an arrow must ignore that and keep the `this` of the scope it
// was written in. A top-level arrow has no enclosing function to capture from,
// which is exactly where that used to go wrong.

const EventEmitter = require('events');

const out = [];

function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'symbol') return v.toString();
  if (typeof v === 'function') return 'fn:' + (v.name || '?');
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
  if (v instanceof Error) return v.constructor.name + '(' + v.message + ')';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}

function T(label, fn) {
  let v;
  try { v = fn(); } catch (e) {
    v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)) +
        (e && e.message ? ':' + e.message : '');
  }
  out.push(label + ' = ' + show(v));
}

// --- registration and emit --------------------------------------------------

T('module-shape', () => [typeof EventEmitter, typeof EventEmitter.EventEmitter,
                         EventEmitter.EventEmitter === EventEmitter]);
T('basic-emit', () => {
  const e = new EventEmitter();
  const seen = [];
  e.on('x', (a, b) => seen.push(a + ':' + b));
  const r = e.emit('x', 1, 2);
  return [r, seen];
});
T('emit-no-listeners', () => new EventEmitter().emit('nothing'));
T('emit-many-args', () => {
  const e = new EventEmitter();
  let got;
  e.on('x', (...a) => { got = a; });
  e.emit('x', 1, 'two', null, undefined, 5);
  return got;
});
T('on-returns-emitter', () => {
  const e = new EventEmitter();
  return e.on('x', () => {}) === e;
});
T('addListener-alias', () => {
  const e = new EventEmitter();
  const seen = [];
  e.addListener('x', () => seen.push('a'));
  e.emit('x');
  return [seen, EventEmitter.prototype.addListener === EventEmitter.prototype.on];
});
T('listener-order', () => {
  const e = new EventEmitter();
  const seen = [];
  e.on('x', () => seen.push(1));
  e.on('x', () => seen.push(2));
  e.on('x', () => seen.push(3));
  e.emit('x');
  return seen;
});
T('prependListener', () => {
  const e = new EventEmitter();
  const seen = [];
  e.on('x', () => seen.push('second'));
  e.prependListener('x', () => seen.push('first'));
  e.emit('x');
  return seen;
});
T('duplicate-listener-fires-twice', () => {
  const e = new EventEmitter();
  let n = 0;
  const f = () => { n++; };
  e.on('x', f).on('x', f);
  e.emit('x');
  return [n, e.listenerCount('x')];
});
T('this-is-emitter', () => {
  const e = new EventEmitter();
  let self;
  e.on('x', function () { self = this; });
  e.emit('x');
  return self === e;
});
T('arrow-this-not-emitter', () => {
  const e = new EventEmitter();
  let self = 'unset';
  e.on('x', () => { self = this; });
  e.emit('x');
  return self === e;
});
T('symbol-event', () => {
  const S = Symbol('ev');
  const e = new EventEmitter();
  const seen = [];
  e.on(S, () => seen.push('fired'));
  return [e.emit(S), seen, e.listenerCount(S)];
});
T('non-function-listener', () => {
  const e = new EventEmitter();
  try { e.on('x', 5); return 'no-throw'; } catch (err) { return 'THROW:' + err.constructor.name; }
});

// --- once -------------------------------------------------------------------

T('once-fires-once', () => {
  const e = new EventEmitter();
  let n = 0;
  e.once('x', () => { n++; });
  e.emit('x'); e.emit('x'); e.emit('x');
  return [n, e.listenerCount('x')];
});
T('once-args', () => {
  const e = new EventEmitter();
  let got;
  e.once('x', (...a) => { got = a; });
  e.emit('x', 1, 2);
  return got;
});
T('once-removed-before-firing', () => {
  const e = new EventEmitter();
  let n = 0;
  const f = () => { n++; };
  e.once('x', f);
  e.removeListener('x', f);
  e.emit('x');
  return [n, e.listenerCount('x')];
});
T('once-order-with-on', () => {
  const e = new EventEmitter();
  const seen = [];
  e.on('x', () => seen.push('on'));
  e.once('x', () => seen.push('once'));
  e.emit('x');
  e.emit('x');
  return seen;
});
T('prependOnceListener', () => {
  const e = new EventEmitter();
  const seen = [];
  e.on('x', () => seen.push('on'));
  e.prependOnceListener('x', () => seen.push('once'));
  e.emit('x');
  e.emit('x');
  return seen;
});
T('once-removed-during-own-call', () => {
  const e = new EventEmitter();
  const counts = [];
  e.once('x', () => counts.push(e.listenerCount('x')));
  e.emit('x');
  return counts;
});

// --- removal ----------------------------------------------------------------

T('removeListener', () => {
  const e = new EventEmitter();
  const seen = [];
  const f = () => seen.push('f');
  e.on('x', f);
  e.on('x', () => seen.push('g'));
  e.removeListener('x', f);
  e.emit('x');
  return [seen, e.listenerCount('x')];
});
T('removeListener-removes-one-of-duplicates', () => {
  const e = new EventEmitter();
  let n = 0;
  const f = () => { n++; };
  e.on('x', f).on('x', f);
  e.removeListener('x', f);
  e.emit('x');
  return [n, e.listenerCount('x')];
});
T('off-alias', () => {
  const e = new EventEmitter();
  const f = () => {};
  e.on('x', f).off('x', f);
  return [e.listenerCount('x'), EventEmitter.prototype.off === EventEmitter.prototype.removeListener];
});
T('removeListener-unknown', () => {
  const e = new EventEmitter();
  return e.removeListener('x', () => {}) === e;
});
T('removeAllListeners-one-event', () => {
  const e = new EventEmitter();
  e.on('x', () => {}).on('x', () => {}).on('y', () => {});
  const r = e.removeAllListeners('x');
  return [e.listenerCount('x'), e.listenerCount('y'), r === e];
});
T('removeAllListeners-everything', () => {
  const e = new EventEmitter();
  e.on('x', () => {}).on('y', () => {});
  e.removeAllListeners();
  return [e.listenerCount('x'), e.listenerCount('y'), e.eventNames()];
});

// --- mutation during emit ---------------------------------------------------

// emit iterates a copy, so a listener removed while the event is dispatching
// still runs this time
T('remove-during-emit', () => {
  const e = new EventEmitter();
  const seen = [];
  const b = () => seen.push('b');
  e.on('x', () => { seen.push('a'); e.removeListener('x', b); });
  e.on('x', b);
  e.emit('x');
  e.emit('x');
  return seen;
});
T('add-during-emit-not-called', () => {
  const e = new EventEmitter();
  const seen = [];
  e.on('x', () => {
    seen.push('a');
    e.on('x', () => seen.push('added'));
  });
  e.emit('x');
  return seen;
});
T('removeAll-during-emit', () => {
  const e = new EventEmitter();
  const seen = [];
  e.on('x', () => { seen.push('a'); e.removeAllListeners('x'); });
  e.on('x', () => seen.push('b'));
  e.emit('x');
  return [seen, e.listenerCount('x')];
});
T('throwing-listener-stops-rest', () => {
  const e = new EventEmitter();
  const seen = [];
  e.on('x', () => { seen.push('a'); throw new Error('boom'); });
  e.on('x', () => seen.push('b'));
  try { e.emit('x'); } catch (err) { seen.push('caught:' + err.message); }
  return seen;
});

// --- the error contract -----------------------------------------------------

T('error-without-listener-throws', () => {
  const e = new EventEmitter();
  try { e.emit('error', new RangeError('bad')); return 'no-throw'; }
  catch (err) { return [err.constructor.name, err.message]; }
});
T('error-with-listener', () => {
  const e = new EventEmitter();
  let got;
  e.on('error', (err) => { got = err.message; });
  return [e.emit('error', new Error('handled')), got];
});
T('error-once-listener', () => {
  const e = new EventEmitter();
  let n = 0;
  e.once('error', () => { n++; });
  e.emit('error', new Error('a'));
  try { e.emit('error', new Error('b')); } catch (err) { return [n, 'threw-second']; }
  return [n, 'no-second-throw'];
});
T('non-error-event-safe-without-listener', () => {
  const e = new EventEmitter();
  return e.emit('clientError', new Error('x'));
});

// --- introspection ----------------------------------------------------------

T('listenerCount-method', () => {
  const e = new EventEmitter();
  e.on('x', () => {}).on('x', () => {});
  return [e.listenerCount('x'), e.listenerCount('none')];
});
T('listeners', () => {
  const e = new EventEmitter();
  const f = function named() {};
  e.on('x', f);
  const l = e.listeners('x');
  return [l.length, l[0] === f, Array.isArray(l)];
});
T('listeners-is-a-copy', () => {
  const e = new EventEmitter();
  e.on('x', () => {});
  const l = e.listeners('x');
  l.push(() => {});
  return e.listenerCount('x');
});
T('listeners-empty', () => {
  const e = new EventEmitter();
  return [e.listeners('none'), e.listeners('none').length];
});
T('listeners-unwraps-once', () => {
  const e = new EventEmitter();
  const f = function target() {};
  e.once('x', f);
  return e.listeners('x')[0] === f;
});
T('rawListeners-keeps-wrapper', () => {
  const e = new EventEmitter();
  const f = function target() {};
  e.once('x', f);
  const raw = e.rawListeners('x');
  return typeof raw[0] === 'function' ? [raw.length, raw[0] === f, raw[0].listener === f] : 'missing';
});
T('eventNames', () => {
  const e = new EventEmitter();
  const S = Symbol('s');
  e.on('b', () => {}).on('a', () => {}).on(S, () => {});
  const names = e.eventNames();
  return [names.length, names.slice(0, 2), typeof names[2]];
});
T('eventNames-after-removal', () => {
  const e = new EventEmitter();
  const f = () => {};
  e.on('x', f);
  e.removeListener('x', f);
  return e.eventNames();
});
T('maxListeners', () => {
  const e = new EventEmitter();
  const before = e.getMaxListeners();
  e.setMaxListeners(3);
  return [before, e.getMaxListeners(), typeof EventEmitter.defaultMaxListeners];
});
T('setMaxListeners-returns-this', () => {
  const e = new EventEmitter();
  return e.setMaxListeners(5) === e;
});
T('listenerCount-static', () => {
  const e = new EventEmitter();
  e.on('x', () => {});
  return typeof EventEmitter.listenerCount === 'function'
    ? EventEmitter.listenerCount(e, 'x') : 'missing';
});

// --- meta events ------------------------------------------------------------

T('newListener', () => {
  const e = new EventEmitter();
  const seen = [];
  e.on('newListener', (name) => seen.push('new:' + String(name)));
  e.on('x', () => {});
  e.once('y', () => {});
  return seen;
});
T('newListener-fires-before-add', () => {
  const e = new EventEmitter();
  let countAtEvent = -1;
  e.on('newListener', () => { countAtEvent = e.listenerCount('x'); });
  e.on('x', () => {});
  return [countAtEvent, e.listenerCount('x')];
});
T('removeListener-meta', () => {
  const e = new EventEmitter();
  const seen = [];
  const f = () => {};
  e.on('removeListener', (name) => seen.push('rm:' + String(name)));
  e.on('x', f);
  e.removeListener('x', f);
  return seen;
});

// --- inheritance ------------------------------------------------------------

T('subclass', () => {
  class Thing extends EventEmitter {
    constructor() { super(); this.tag = 'T'; }
    fire() { return this.emit('go', this.tag); }
  }
  const t = new Thing();
  const seen = [];
  t.on('go', (v) => seen.push(v));
  return [t.fire(), seen, t instanceof EventEmitter, t instanceof Thing];
});
T('subclass-without-super-fields', () => {
  class Thing extends EventEmitter {}
  const a = new Thing();
  const b = new Thing();
  a.on('x', () => {});
  return [a.listenerCount('x'), b.listenerCount('x')];
});

console.log(out.join('\n'));

// Error.captureStackTrace, Error.stackTraceLimit, how an error prints, and
// the hook an object can use to say how it prints.
//
// Stack text is machine-specific, so nothing here compares frames. The cases
// that print an error replace its stack with a fixed string first, which is
// what makes the output stable; the frame-counting cases only count lines.

const util = require('util');
const rows = [];
function T(label, fn) {
  let v;
  try { v = JSON.stringify(fn()); }
  catch (e) { v = 'THROW:' + (e && e.name ? e.name : String(e)); }
  rows.push(label + ' = ' + v);
}
const fixed = (e) => { e.stack = e.name + ': ' + e.message; return e; };

// --- Error.captureStackTrace ------------------------------------------------
T('exists', () => typeof Error.captureStackTrace);
T('returns-undefined', () => { const o = {}; return Error.captureStackTrace(o) === undefined; });
T('plain-object-header', () => { const o = {}; Error.captureStackTrace(o); return o.stack.split('\n')[0]; });
T('named-object-header', () => { const o = { name: 'Custom', message: 'boom' }; Error.captureStackTrace(o); return o.stack.split('\n')[0]; });
T('not-enumerable', () => { const o = {}; Error.captureStackTrace(o); return Object.keys(o).join(','); });
T('subclass-header', () => {
  class E extends Error {
    constructor(m) { super(m); this.name = 'E'; Error.captureStackTrace(this, E); }
  }
  return new E('oops').stack.split('\n')[0];
});
T('hides-constructor-frame', () => {
  class E extends Error {
    constructor(m) { super(m); Error.captureStackTrace(this, E); }
  }
  function make() { return new E('x'); }
  const lines = make().stack.split('\n');
  return lines[1].includes('make');
});
T('frames-look-right', () => {
  const o = {};
  Error.captureStackTrace(o);
  return o.stack.split('\n')[1].trim().slice(0, 3);
});
T('non-object', () => Error.captureStackTrace(5));
T('stack-writable', () => { const e = new Error('x'); e.stack = 'replaced'; return e.stack; });

// --- Error.stackTraceLimit --------------------------------------------------
T('limit-default', () => Error.stackTraceLimit);
T('limit-zero', () => {
  const old = Error.stackTraceLimit;
  Error.stackTraceLimit = 0;
  const n = new Error('x').stack.split('\n').length;
  Error.stackTraceLimit = old;
  return n;
});
T('limit-two', () => {
  const old = Error.stackTraceLimit;
  Error.stackTraceLimit = 2;
  function a() { return new Error('x').stack; }
  function b() { return a(); }
  const n = b().split('\n').length;
  Error.stackTraceLimit = old;
  return n;
});
T('limit-restored', () => Error.stackTraceLimit);
T('limit-applies-to-capture', () => {
  const old = Error.stackTraceLimit;
  Error.stackTraceLimit = 1;
  const o = {};
  function a() { Error.captureStackTrace(o); }
  function b() { a(); }
  b();
  const n = o.stack.split('\n').length;
  Error.stackTraceLimit = old;
  return n;
});

// --- how an error prints ----------------------------------------------------
T('inspect-plain', () => util.inspect(fixed(new Error('boom'))));
T('inspect-extra-prop', () => util.inspect(Object.assign(fixed(new Error('boom')), { code: 'E1' })));
T('inspect-two-extras', () => util.inspect(Object.assign(fixed(new Error('boom')), { code: 'E1', detail: { a: 1 } })));
T('inspect-cause', () => util.inspect(fixed(new Error('outer', { cause: fixed(new Error('inner')) }))));
T('inspect-aggregate', () => util.inspect(fixed(new AggregateError([fixed(new RangeError('a'))], 'many'))));
T('inspect-subclass-name-once', () => {
  class E extends Error { constructor() { super('m'); this.name = 'E'; this.x = 1; } }
  return util.inspect(fixed(new E()));
});
T('inspect-in-object', () => util.inspect({ err: fixed(new Error('nested')) }));
T('inspect-in-array', () => util.inspect([fixed(new TypeError('t'))]));
T('inspect-with-frames', () => {
  const e = new Error('framed');
  e.stack = 'Error: framed\n    at fake (a.js:1:1)';
  e.code = 'E2';
  return util.inspect(e);
});
T('inspect-no-message', () => util.inspect(fixed(new Error())));

// --- an object that says how it prints --------------------------------------
T('custom-string', () => util.inspect({ [util.inspect.custom]() { return 'CUSTOM'; } }));
T('custom-nonstring', () => util.inspect({ [util.inspect.custom]() { return { a: 1 }; } }));
T('custom-nested', () => util.inspect({ k: { [util.inspect.custom]() { return 'INNER'; } } }));
T('custom-args', () => {
  let seen = null;
  const o = { [util.inspect.custom](d, opts, insp) { seen = [typeof d, typeof opts, typeof insp]; return 'X'; } };
  util.inspect(o);
  return seen.join(',');
});
T('custom-this', () => {
  const o = { tag: 'me', [util.inspect.custom]() { return 'I am ' + this.tag; } };
  return util.inspect(o);
});
T('custom-symbol-for', () => {
  const s = Symbol.for('nodejs.util.inspect.custom');
  return [s === util.inspect.custom, util.inspect({ [s]() { return 'VIA-FOR'; } })].join(',');
});
T('custom-in-array', () => util.inspect([{ [util.inspect.custom]() { return 'A'; } }]));
T('custom-on-class', () => {
  class Money {
    constructor(v) { this.v = v; }
    [util.inspect.custom]() { return 'Money(' + this.v + ')'; }
  }
  return util.inspect(new Money(5));
});
T('custom-not-callable-ignored', () => util.inspect({ [util.inspect.custom]: 5, a: 1 }));

console.log(rows.join('\n'));

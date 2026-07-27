// Error types and the control flow around try/catch/finally, where the
// interactions between return, break and finally are easy to get wrong.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// The built-in error types and their shape.
T('error-message', () => new Error('m').message);
T('error-name', () => new Error('m').name);
T('error-toString', () => String(new Error('m')));
T('error-toString-empty', () => String(new Error()));
T('error-instanceof', () => { const e = new Error('m'); return [e instanceof Error, e instanceof Object]; });
T('error-stack-type', () => typeof new Error('x').stack);
T('error-cause', () => new Error('m', { cause: 'c' }).cause);
T('error-no-cause', () => 'cause' in new Error('m'));
T('typeerror', () => { const e = new TypeError('t'); return [e.name, e instanceof TypeError, e instanceof Error]; });
T('rangeerror', () => { const e = new RangeError('r'); return [e.name, e instanceof RangeError]; });
T('syntaxerror', () => new SyntaxError('s').name);
T('referenceerror', () => new ReferenceError('r').name);
T('evalerror', () => new EvalError('e').name);
T('urierror', () => new URIError('u').name);
T('error-message-not-enumerable', () => Object.keys(new Error('m')));

// Errors thrown by the language itself.
T('throws-typeerror-call', () => { const x = 1; x(); });
T('throws-typeerror-prop', () => { const x = null; return x.y; });
T('throws-referenceerror', () => notDefinedAnywhere);
T('throws-rangeerror-array', () => new Array(-1));
T('throws-rangeerror-toFixed', () => (1).toFixed(101));
T('throws-uri', () => decodeURIComponent('%'));

// Subclassing.
T('custom-error', () => {
  class E extends Error { constructor(m) { super(m); this.name = 'E'; } }
  const e = new E('m');
  return [e.message, e.name, e instanceof E, e instanceof Error, String(e)];
});
T('custom-error-own-field', () => {
  class E extends Error { constructor() { super('m'); this.code = 42; } }
  return new E().code;
});
T('custom-error-catch', () => {
  class E extends Error { }
  try { throw new E('x'); } catch (e) { return [e instanceof E, e.message]; }
});

// try / catch / finally control flow.
T('finally-runs', () => { const log = []; try { log.push('t'); } finally { log.push('f'); } return log; });
T('finally-after-throw', () => { const log = []; try { throw new Error('x'); } catch (e) { log.push('c'); } finally { log.push('f'); } return log; });
T('finally-return-wins', () => { function f() { try { return 1; } finally { return 2; } } return f(); });
T('finally-does-not-override', () => { function f() { try { return 1; } finally { } } return f(); });
T('finally-runs-on-return', () => { const log = []; function f() { try { return 1; } finally { log.push('f'); } } f(); return log; });
T('finally-swallows-throw', () => { function f() { try { throw new Error('x'); } finally { return 'ok'; } } return f(); });
T('finally-rethrows', () => { function f() { try { throw new Error('a'); } finally { } } try { f(); } catch (e) { return e.message; } });
T('nested-finally-order', () => {
  const log = [];
  try { try { throw new Error('x'); } finally { log.push('inner'); } } catch (e) { log.push('outer'); }
  return log;
});
T('catch-rethrow', () => { try { try { throw new Error('a'); } catch (e) { throw new Error('b'); } } catch (e) { return e.message; } });
T('catch-binding-scope', () => { let e = 'outer'; try { throw 1; } catch (e) { } return e; });
T('catch-no-binding', () => { try { throw 1; } catch { return 'ok'; } });
T('throw-non-error', () => { try { throw 'plain'; } catch (e) { return [typeof e, e]; } });
T('throw-object', () => { try { throw { code: 1 }; } catch (e) { return e.code; } });
T('throw-in-finally-replaces', () => {
  try { try { throw new Error('a'); } finally { throw new Error('b'); } } catch (e) { return e.message; }
});
T('finally-with-break', () => {
  const log = [];
  for (const v of [1, 2]) { try { if (v === 1) break; } finally { log.push('f' + v); } }
  return log;
});
T('finally-with-continue', () => {
  const log = [];
  for (const v of [1, 2]) { try { continue; } finally { log.push('f' + v); } }
  return log;
});
T('try-in-loop', () => { const log = []; for (let i = 0; i < 2; i++) { try { throw new Error(); } catch (e) { log.push(i); } } return log; });
T('return-in-catch', () => { function f() { try { throw new Error(); } catch (e) { return 'c'; } finally { } } return f(); });
T('nested-catch-value', () => { try { throw 1; } catch (a) { try { throw 2; } catch (b) { return [a, b]; } } });

// Rejections surface as thrown values under await.
T('error-in-getter', () => { const o = { get v() { throw new TypeError('g'); } }; try { o.v; } catch (e) { return e.name; } });
T('error-in-setter', () => { const o = { set v(x) { throw new RangeError('s'); } }; try { o.v = 1; } catch (e) { return e.name; } });

console.log(rows.join('\n'));

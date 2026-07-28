// Error semantics: construction and message coercion, toString, the native
// error types, `cause`, what is enumerable and what serializes, stack shape,
// subclassing, AggregateError, and throwing non-errors.
//
// The stack's contents are engine-specific, so only its type, its first line
// and whether it is enumerable are asserted.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// --- construction ---
T('basic', () => { const e = new Error('boom'); return [e.message, e.name]; });
T('no-message', () => { const e = new Error(); return [e.message, e.name]; });
T('undefined-message', () => new Error(undefined).message);
T('message-coerced', () => [new Error(5).message, new Error(null).message, new Error({}).message]);
T('without-new', () => { const e = Error('x'); return [e instanceof Error, e.message]; });
T('constructor-prop', () => new Error('x').constructor.name);
T('proto-chain', () => Object.getPrototypeOf(new TypeError('x')) === TypeError.prototype);
T('name-on-proto', () => [Object.hasOwn(new Error('x'), 'name'), Error.prototype.name]);
T('message-own', () => Object.hasOwn(new Error('x'), 'message'));
T('message-default-proto', () => JSON.stringify(Error.prototype.message));

// --- toString ---
T('tostring-both', () => String(new Error('boom')));
T('tostring-no-message', () => String(new Error()));
T('tostring-custom-name', () => { const e = new Error('m'); e.name = 'Custom'; return String(e); });
T('tostring-empty-name', () => { const e = new Error('m'); e.name = ''; return String(e); });
T('tostring-typeerror', () => String(new TypeError('t')));
T('tostring-via-proto', () => Error.prototype.toString.call({ name: 'N', message: 'M' }));
T('template-interp', () => `${new RangeError('r')}`);

// --- the native error types ---
T('types-exist', () => [TypeError, RangeError, SyntaxError, ReferenceError, EvalError, URIError].map((c) => typeof c));
T('types-names', () => [new TypeError(''), new RangeError(''), new SyntaxError(''), new ReferenceError(''), new EvalError(''), new URIError('')].map((e) => e.name));
T('types-instanceof-error', () => [new TypeError('') instanceof Error, new RangeError('') instanceof Error]);
T('types-not-cross', () => new TypeError('') instanceof RangeError);
T('error-not-typeerror', () => new Error('') instanceof TypeError);

// --- cause ---
T('cause-present', () => { const e = new Error('m', { cause: 'why' }); return [e.cause, Object.hasOwn(e, 'cause')]; });
T('cause-absent', () => { const e = new Error('m'); return ['cause' in e, e.cause]; });
T('cause-undefined-explicit', () => { const e = new Error('m', { cause: undefined }); return Object.hasOwn(e, 'cause'); });
T('cause-object', () => { const inner = new Error('inner'); return new Error('outer', { cause: inner }).cause.message; });
T('cause-not-enumerable', () => { const e = new Error('m', { cause: 1 }); return Object.keys(e); });
T('cause-on-subtype', () => new TypeError('m', { cause: 7 }).cause);
T('cause-ignored-non-object', () => { const e = new Error('m', 'nope'); return 'cause' in e; });

// --- enumerability and serialization ---
T('keys-empty', () => Object.keys(new Error('m')));
T('json-empty', () => JSON.stringify(new Error('m')));
T('json-with-own', () => { const e = new Error('m'); e.code = 'E1'; return JSON.stringify(e); });
T('spread-empty', () => JSON.stringify({ ...new Error('m') }));
T('message-not-enumerable', () => Object.getOwnPropertyDescriptor(new Error('m'), 'message').enumerable);
T('assigned-prop-enumerable', () => { const e = new Error('m'); e.x = 1; return Object.keys(e); });

// --- stack ---
T('stack-is-string', () => typeof new Error('m').stack);
T('stack-mentions-message', () => new Error('boom').stack.includes('boom'));
T('stack-first-line', () => new Error('boom').stack.split('\n')[0]);
T('stack-not-enumerable', () => Object.keys(new Error('m')).includes('stack'));
T('stack-writable', () => { const e = new Error('m'); e.stack = 'replaced'; return e.stack; });

// --- subclassing ---
T('subclass-message', () => { class E extends Error {} return new E('m').message; });
T('subclass-name-default', () => { class E extends Error {} return new E('m').name; });
T('subclass-name-set', () => { class E extends Error { constructor(m) { super(m); this.name = 'E'; } } return [new E('m').name, String(new E('m'))]; });
T('subclass-instanceof', () => { class E extends Error {} const e = new E('m'); return [e instanceof E, e instanceof Error]; });
T('subclass-extra-field', () => { class E extends Error { constructor(m, c) { super(m); this.code = c; } } const e = new E('m', 42); return [e.code, e.message, Object.keys(e)]; });
T('subclass-of-typeerror', () => { class E extends TypeError {} const e = new E('m'); return [e instanceof TypeError, e instanceof Error, e.name]; });
T('subclass-stack', () => { class E extends Error {} return typeof new E('m').stack; });
T('subclass-cause', () => { class E extends Error {} return new E('m', { cause: 1 }).cause; });

// --- AggregateError ---
T('aggregate-exists', () => typeof AggregateError);
T('aggregate-basic', () => { const e = new AggregateError([new Error('a')], 'many'); return [e.message, e.name, e.errors.length]; });
T('aggregate-instanceof', () => new AggregateError([], 'm') instanceof Error);
T('aggregate-errors-iterable', () => new AggregateError(new Set([1, 2]), 'm').errors);
T('aggregate-no-message', () => new AggregateError([]).message);
T('aggregate-errors-not-enumerable', () => Object.keys(new AggregateError([1], 'm')));

// --- throwing and catching ---
T('throw-non-error', () => { try { throw 'plain'; } catch (e) { return [typeof e, e]; } });
T('throw-null', () => { try { throw null; } catch (e) { return e; } });
T('rethrow-preserves', () => { const orig = new Error('m'); try { try { throw orig; } catch (e) { throw e; } } catch (e2) { return e2 === orig; } });
T('catch-binding-optional', () => { try { throw 1; } catch { return 'caught'; } });
T('finally-after-throw', () => { const o = []; try { try { throw new Error('m'); } finally { o.push('f'); } } catch (e) { o.push('c'); } return o; });
T('error-in-getter-propagates', () => { const o = { get a() { throw new RangeError('g'); } }; try { o.a; } catch (e) { return e.name; } });
T('nested-cause-chain', () => { const a = new Error('a'); const b = new Error('b', { cause: a }); const c = new Error('c', { cause: b }); return c.cause.cause.message; });

T('aggregate-tostring', () => String(new AggregateError([], 'm')));
T('aggregate-cause', () => new AggregateError([], 'm', { cause: 9 }).cause);
T('aggregate-errors-own', () => Object.hasOwn(new AggregateError([1], 'm'), 'errors'));
T('aggregate-ctor-name', () => new AggregateError([], 'm').constructor.name);
T('aggregate-subclass', () => { class A extends AggregateError {} const a = new A([1], 'm'); return [a.errors.length, a instanceof AggregateError, a instanceof Error]; });

console.log(rows.join('\n'));

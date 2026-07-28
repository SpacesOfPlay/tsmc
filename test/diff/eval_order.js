// Evaluation order: which operand runs first, what a short circuit skips, and
// how many times a compound assignment evaluates its base and key. `t` records
// a step and returns its value, so the log is the order.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}
// `L` records a step and returns its value, so order shows up in the log.
function mk() { const log = []; const t = (s, v) => { log.push(s); return v; }; return [log, t]; }

// --- binary and unary operands ---
T('binary-lr', () => { const [o, t] = mk(); t('a', 1) + t('b', 2); return o; });
T('binary-nested', () => { const [o, t] = mk(); (t('a', 1) + t('b', 2)) * t('c', 3); return o; });
T('compare-lr', () => { const [o, t] = mk(); t('a', 1) < t('b', 2); return o; });
T('in-lr', () => { const [o, t] = mk(); t('k', 'x') in t('o', { x: 1 }); return o; });
T('instanceof-lr', () => { const [o, t] = mk(); t('v', {}) instanceof t('c', Object); return o; });
T('comma', () => { const [o, t] = mk(); const r = (t('a', 1), t('b', 2)); return [o, r]; });
T('exponent-right-assoc', () => 2 ** 3 ** 2);
T('unary-minus-order', () => { const [o, t] = mk(); -t('a', 1); return o; });
T('typeof-evaluates', () => { const [o, t] = mk(); typeof t('a', 1); return o; });
T('void-evaluates', () => { const [o, t] = mk(); void t('a', 1); return o; });

// ToPrimitive ordering inside `+`
T('add-toprimitive-order', () => {
  const [o, t] = mk();
  const A = { valueOf() { return t('A', 1); } };
  const B = { valueOf() { return t('B', 2); } };
  A + B; return o;
});
T('add-string-hint-once', () => { let n = 0; const A = { toString() { n++; return 'a'; } }; A + 'x'; return n; });

// --- member access and calls ---
T('call-callee-before-args', () => { const [o, t] = mk(); const f = () => {}; (t('callee', f))(t('arg', 1)); return o; });
T('call-args-lr', () => { const [o, t] = mk(); const f = () => {}; f(t('a', 1), t('b', 2), t('c', 3)); return o; });
T('method-base-before-args', () => { const [o, t] = mk(); const obj = { m() {} }; t('base', obj).m(t('arg', 1)); return o; });
T('member-key-order', () => { const [o, t] = mk(); const obj = {}; t('base', obj)[t('key', 'k')]; return o; });
T('new-callee-before-args', () => { const [o, t] = mk(); class C { constructor() {} } new (t('ctor', C))(t('arg', 1)); return o; });
T('spread-order', () => { const [o, t] = mk(); const f = () => {}; f(t('a', 1), ...t('spread', [2]), t('c', 3)); return o; });
T('getter-fires-once-on-call', () => { let n = 0; const obj = { get m() { n++; return () => {}; } }; obj.m(); return n; });
T('optional-call-base-once', () => { let n = 0; const obj = { get m() { n++; return () => 1; } }; obj?.m(); return n; });

// --- assignment ---
T('assign-target-before-value', () => { const [o, t] = mk(); const obj = {}; t('base', obj)[t('key', 'k')] = t('value', 1); return o; });
T('assign-returns-value', () => { const obj = {}; return (obj.x = 5); });
T('compound-key-once', () => { let n = 0; const obj = { k: 1 }; const key = () => { n++; return 'k'; }; obj[key()] += 1; return [n, obj.k]; });
T('compound-order', () => { const [o, t] = mk(); const obj = { k: 1 }; t('base', obj)[t('key', 'k')] += t('value', 2); return o; });
T('logical-assign-key-once', () => { let n = 0; const obj = { k: 0 }; const key = () => { n++; return 'k'; }; obj[key()] ||= 9; return [n, obj.k]; });
T('logical-assign-skips-value', () => { const [o, t] = mk(); const obj = { k: 1 }; obj.k ||= t('rhs', 2); return o; });
T('incdec-base-once', () => { let n = 0; const obj = { k: 1 }; const base = () => { n++; return obj; }; base().k++; return [n, obj.k]; });
T('incdec-key-once', () => { let n = 0; const obj = { k: 1 }; const key = () => { n++; return 'k'; }; obj[key()]++; return [n, obj.k]; });
T('postfix-returns-old', () => { let x = 1; return [x++, x]; });
T('prefix-returns-new', () => { let x = 1; return [++x, x]; });
T('chained-assign-order', () => { const [o, t] = mk(); const a = {}, b = {}; t('a', a).x = t('b', b).y = t('v', 1); return o; });

// --- short circuit ---
T('and-skips-rhs', () => { const [o, t] = mk(); false && t('rhs', 1); return o; });
T('or-skips-rhs', () => { const [o, t] = mk(); true || t('rhs', 1); return o; });
T('nullish-skips-rhs', () => { const [o, t] = mk(); 0 ?? t('rhs', 1); return o; });
T('nullish-takes-rhs-on-null', () => { const [o, t] = mk(); null ?? t('rhs', 1); return o; });
T('ternary-one-branch', () => { const [o, t] = mk(); true ? t('then', 1) : t('else', 2); return o; });
T('optional-chain-skips-key', () => { const [o, t] = mk(); const obj = null; obj?.[t('key', 'k')]; return o; });
T('optional-chain-skips-args', () => { const [o, t] = mk(); const obj = null; obj?.m(t('arg', 1)); return o; });
T('optional-chain-short-circuits-whole', () => { const [o, t] = mk(); const obj = null; obj?.a.b[t('key', 'k')]; return o; });
T('optional-chain-non-null-evaluates', () => { const [o, t] = mk(); const obj = { k: 1 }; obj?.[t('key', 'k')]; return o; });
T('and-returns-operand', () => [1 && 2, 0 && 2, null && 2]);
T('or-returns-operand', () => [1 || 2, 0 || 2, '' || 'x']);

// --- literals ---
T('array-literal-order', () => { const [o, t] = mk(); [t('a', 1), t('b', 2)]; return o; });
T('object-literal-order', () => { const [o, t] = mk(); ({ a: t('a', 1), b: t('b', 2) }); return o; });
T('object-computed-key-before-value', () => { const [o, t] = mk(); ({ [t('key', 'k')]: t('value', 1) }); return o; });
T('template-order', () => { const [o, t] = mk(); `${t('a', 1)}-${t('b', 2)}`; return o; });
T('tagged-template-order', () => { const [o, t] = mk(); const tag = () => {}; tag`${t('a', 1)}${t('b', 2)}`; return o; });
T('object-dup-key-last-wins', () => JSON.stringify({ a: 1, a: 2 }));
T('object-getter-not-invoked-on-define', () => { let n = 0; const o = { get a() { n++; return 1; } }; return n; });

// --- accessors and receivers ---
T('setter-on-proto-invoked', () => { const log = []; const proto = { set v(x) { log.push('setter:' + x); } }; const o = Object.create(proto); o.v = 1; return [log, Object.hasOwn(o, 'v')]; });
T('getter-this-is-receiver', () => { const proto = { get who() { return this.tag; } }; const o = Object.create(proto); o.tag = 'child'; return o.who; });
T('reflect-set-receiver', () => { const log = []; const target = { set v(x) { log.push('t'); } }; const recv = {}; Reflect.set(target, 'v', 1, recv); return log; });
T('defineProperty-bypasses-setter', () => { const log = []; const proto = { set v(x) { log.push('setter'); } }; const o = Object.create(proto); Object.defineProperty(o, 'v', { value: 1, enumerable: true, configurable: true, writable: true }); return [log, o.v]; });
T('assign-invokes-setter', () => { const log = []; const src = { a: 1 }; const dst = { set a(x) { log.push('setter'); } }; Object.assign(dst, src); return log; });
T('spread-does-not-invoke-setter', () => { const log = []; const proto = { set a(x) { log.push('setter'); } }; const dst = { ...{ a: 1 } }; return [log, dst.a]; });

console.log(rows.join('\n'));

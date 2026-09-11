// A module namespace object is not an ordinary object: its names are the
// module's exports, nothing outside the module may write or delete one, the
// set does not grow, and the names read in code unit order.

import * as ns from './esm_ns/exports.mjs';
import * as star from './esm_ns/star.mjs';

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

T('typeof', () => typeof ns);
T('the prototype', () => Object.getPrototypeOf(ns));
T('toStringTag', () => ns[Symbol.toStringTag]);
T('what toString says', () => Object.prototype.toString.call(ns));
T('one symbol, not enumerable', () => JSON.stringify([
  Object.getOwnPropertySymbols(ns).length,
  Object.getOwnPropertyDescriptor(ns, Symbol.toStringTag),
]));

T('the names, in order', () => JSON.stringify(Object.keys(ns)));
T('getOwnPropertyNames agrees', () => JSON.stringify(Object.getOwnPropertyNames(ns)));
T('and so does a for-in', () => { const out = []; for (const k in ns) out.push(k); return JSON.stringify(out); });

T('a descriptor', () => JSON.stringify(Object.getOwnPropertyDescriptor(ns, 'zeta')));
T('a const is no different', () => JSON.stringify(Object.getOwnPropertyDescriptor(ns, 'alpha')));
T('nor is default', () => JSON.stringify(Object.getOwnPropertyDescriptor(ns, 'default')));
T('nor a renamed one', () => JSON.stringify(Object.getOwnPropertyDescriptor(ns, 'beta')));

T('not extensible', () => Object.isExtensible(ns));
T('preventExtensions is allowed', () => { Object.preventExtensions(ns); return 'ok'; });
T('a write to an export', () => { ns.zeta = 9; return 'wrote'; });
T('a write of a new name', () => { ns.fresh = 1; return 'wrote'; });
T('a delete of an export', () => delete ns.zeta);
T('a delete of a name it has not', () => delete ns.absent);
T('defineProperty', () => { Object.defineProperty(ns, 'zeta', { value: 5 }); return 'defined'; });
T('the prototype it has is allowed', () => { Object.setPrototypeOf(ns, null); return 'ok'; });
T('another prototype is not', () => { Object.setPrototypeOf(ns, {}); return 'ok'; });

T('in', () => JSON.stringify(['zeta' in ns, 'absent' in ns, Symbol.toStringTag in ns]));
T('hasOwnProperty', () => JSON.stringify([
  Object.prototype.hasOwnProperty.call(ns, 'alpha'),
  Object.prototype.hasOwnProperty.call(ns, 'absent'),
]));
T('propertyIsEnumerable', () => Object.prototype.propertyIsEnumerable.call(ns, 'alpha'));

T('the values', () => JSON.stringify([ns.alpha, ns.beta, ns.mid(), typeof ns.Cls, ns.default, ns.Z_upper, ns._under]));
T('a live binding still moves', () => { const was = ns.zeta; ns.bump(); return [was, ns.zeta].join(' -> '); });

// export * from another module: the names arrive the same way
T('a star export', () => JSON.stringify(Object.keys(star)));
T('its descriptors match', () => JSON.stringify(Object.getOwnPropertyDescriptor(star, 'alpha')));
T('and it is just as closed', () => { star.alpha = 1; return 'wrote'; });

// spread and destructuring read it like any object
T('spread', () => JSON.stringify(Object.keys({ ...ns })));
T('a spread copy is writable', () => { const c = { ...ns }; c.zeta = 1; return c.zeta; });
T('destructuring', () => { const { alpha, beta, ...rest } = ns; return JSON.stringify([alpha, beta, Object.keys(rest)]); });

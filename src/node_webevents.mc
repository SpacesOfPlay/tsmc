// node_webevents.mc -- DOMException, Event, CustomEvent, EventTarget,
// AbortController / AbortSignal, and performance.
//
// Internal module (require('_webevents')) behind those globals, each of which
// is lazy: a script that never names one pays nothing for it. `perf_hooks`
// hands back the same performance object the global is.
//
// AbortSignal is the cancellation currency of modern code, and it is an
// EventTarget, which is why these live together.
//
// Embedded JS: no backslash escapes (minc processes them in string literals)
// and no double quotes.

str node_webevents_source() {
    return "'use strict';

// The legacy numeric codes. A name that is not one of these reports 0.
const CODES = Object.assign(Object.create(null), {
  IndexSizeError: 1, DOMStringSizeError: 2, HierarchyRequestError: 3,
  WrongDocumentError: 4, InvalidCharacterError: 5, NoDataAllowedError: 6,
  NoModificationAllowedError: 7, NotFoundError: 8, NotSupportedError: 9,
  InUseAttributeError: 10, InvalidStateError: 11, SyntaxError: 12,
  InvalidModificationError: 13, NamespaceError: 14, InvalidAccessError: 15,
  ValidationError: 16, TypeMismatchError: 17, SecurityError: 18,
  NetworkError: 19, AbortError: 20, URLMismatchError: 21,
  QuotaExceededError: 22, TimeoutError: 23, InvalidNodeTypeError: 24,
  DataCloneError: 25,
});

const CONSTANTS = Object.assign(Object.create(null), {
  INDEX_SIZE_ERR: 1, DOMSTRING_SIZE_ERR: 2, HIERARCHY_REQUEST_ERR: 3,
  WRONG_DOCUMENT_ERR: 4, INVALID_CHARACTER_ERR: 5, NO_DATA_ALLOWED_ERR: 6,
  NO_MODIFICATION_ALLOWED_ERR: 7, NOT_FOUND_ERR: 8, NOT_SUPPORTED_ERR: 9,
  INUSE_ATTRIBUTE_ERR: 10, INVALID_STATE_ERR: 11, SYNTAX_ERR: 12,
  INVALID_MODIFICATION_ERR: 13, NAMESPACE_ERR: 14, INVALID_ACCESS_ERR: 15,
  VALIDATION_ERR: 16, TYPE_MISMATCH_ERR: 17, SECURITY_ERR: 18,
  NETWORK_ERR: 19, ABORT_ERR: 20, URL_MISMATCH_ERR: 21,
  QUOTA_EXCEEDED_ERR: 22, TIMEOUT_ERR: 23, INVALID_NODE_TYPE_ERR: 24,
  DATA_CLONE_ERR: 25,
});

function hidden(obj, key, value) {
  Object.defineProperty(obj, key, { value: value, writable: true, enumerable: false, configurable: true });
}

function tag(ctor, name) {
  Object.defineProperty(ctor.prototype, Symbol.toStringTag, { value: name, configurable: true });
}

class DOMException extends Error {
  constructor(message, name) {
    super(message === undefined ? '' : String(message));
    const n = name === undefined ? 'Error' : String(name);
    hidden(this, 'name', n);
    hidden(this, 'code', CODES[n] === undefined ? 0 : CODES[n]);
  }
}
tag(DOMException, 'DOMException');
for (const k of Object.keys(CONSTANTS)) {
  Object.defineProperty(DOMException, k, { value: CONSTANTS[k], enumerable: true });
  Object.defineProperty(DOMException.prototype, k, { value: CONSTANTS[k], enumerable: true });
}

class Event {
  constructor(type, options) {
    if (type === undefined) throw new TypeError('The type argument must be specified');
    const o = options === undefined || options === null ? {} : options;
    this.type = String(type);
    this.bubbles = !!o.bubbles;
    this.cancelable = !!o.cancelable;
    this.composed = !!o.composed;
    this.defaultPrevented = false;
    this.target = null;
    this.currentTarget = null;
    this.eventPhase = 0;
    this.isTrusted = false;
  }
  preventDefault() {
    if (this.cancelable) this.defaultPrevented = true;
  }
  stopPropagation() {}
  stopImmediatePropagation() { this._stopped = true; }
  composedPath() { return this.currentTarget ? [this.currentTarget] : []; }
}
tag(Event, 'Event');

class CustomEvent extends Event {
  constructor(type, options) {
    super(type, options);
    const o = options === undefined || options === null ? {} : options;
    this.detail = o.detail === undefined ? null : o.detail;
  }
}
tag(CustomEvent, 'CustomEvent');

// Listeners are kept in registration order. A listener removed while a
// dispatch is running must not be called, so the walk checks the live list
// rather than only the snapshot it started from.
class EventTarget {
  constructor() {
    hidden(this, '_listeners', new Map());
  }

  addEventListener(type, callback, options) {
    if (callback === undefined || callback === null) return;
    const o = options === undefined || options === null ? {} : (typeof options === 'boolean' ? { capture: options } : options);
    const capture = !!o.capture;
    const key = String(type);
    let list = this._listeners.get(key);
    if (!list) {
      list = [];
      this._listeners.set(key, list);
    }
    for (const e of list) {
      if (e.callback === callback && e.capture === capture) return;
    }
    const entry = { callback: callback, capture: capture, once: !!o.once };
    list.push(entry);
    if (o.signal) {
      if (o.signal.aborted) {
        this.removeEventListener(key, callback, { capture: capture });
      } else {
        o.signal.addEventListener('abort', () => {
          this.removeEventListener(key, callback, { capture: capture });
        }, { once: true });
      }
    }
  }

  removeEventListener(type, callback, options) {
    const o = options === undefined || options === null ? {} : (typeof options === 'boolean' ? { capture: options } : options);
    const capture = !!o.capture;
    const list = this._listeners.get(String(type));
    if (!list) return;
    for (let i = 0; i < list.length; i++) {
      if (list[i].callback === callback && list[i].capture === capture) {
        list.splice(i, 1);
        return;
      }
    }
  }

  dispatchEvent(event) {
    if (!(event instanceof Event)) {
      throw new TypeError('The argument must be an Event');
    }
    const list = this._listeners.get(event.type);
    event.target = this;
    event.currentTarget = this;
    event.eventPhase = 2;
    if (list) {
      const snapshot = list.slice();
      for (const entry of snapshot) {
        if (list.indexOf(entry) < 0) continue;
        if (entry.once) this.removeEventListener(event.type, entry.callback, { capture: entry.capture });
        const cb = entry.callback;
        if (typeof cb === 'function') cb.call(this, event);
        else if (cb && typeof cb.handleEvent === 'function') cb.handleEvent(event);
        if (event._stopped) break;
      }
    }
    event.eventPhase = 0;
    event.currentTarget = null;
    return !(event.cancelable && event.defaultPrevented);
  }
}
tag(EventTarget, 'EventTarget');

// Only AbortController and the statics may build a signal, which is what the
// brand below enforces.
const BRAND = Symbol('AbortSignal');

function doAbort(signal, reason) {
  if (signal._aborted) return;
  signal._aborted = true;
  signal._reason = reason === undefined
    ? new DOMException('This operation was aborted', 'AbortError')
    : reason;
  signal.dispatchEvent(new Event('abort'));
}

class AbortSignal extends EventTarget {
  constructor(brand) {
    super();
    if (brand !== BRAND) throw new TypeError('Illegal constructor');
    hidden(this, '_aborted', false);
    hidden(this, '_reason', undefined);
    hidden(this, '_onabort', null);
  }
  get aborted() { return this._aborted; }
  get reason() { return this._reason; }
  get onabort() { return this._onabort; }
  set onabort(fn) {
    if (this._onabort) this.removeEventListener('abort', this._onabort);
    this._onabort = typeof fn === 'function' ? fn : null;
    if (this._onabort) this.addEventListener('abort', this._onabort);
  }
  throwIfAborted() {
    if (this._aborted) throw this._reason;
  }
  static abort(reason) {
    const s = new AbortSignal(BRAND);
    doAbort(s, reason);
    return s;
  }
  // The timer does not hold the event loop open: a program with nothing else
  // to do should exit rather than wait for a deadline it no longer needs.
  static timeout(ms) {
    const s = new AbortSignal(BRAND);
    const t = setTimeout(() => {
      doAbort(s, new DOMException('The operation was aborted due to timeout', 'TimeoutError'));
    }, ms);
    if (t && typeof t.unref === 'function') t.unref();
    return s;
  }
  static any(signals) {
    const s = new AbortSignal(BRAND);
    const list = [];
    for (const one of signals) list.push(one);
    for (const one of list) {
      if (one.aborted) {
        doAbort(s, one.reason);
        return s;
      }
    }
    for (const one of list) {
      one.addEventListener('abort', () => { doAbort(s, one.reason); }, { once: true });
    }
    return s;
  }
}
tag(AbortSignal, 'AbortSignal');

class AbortController {
  constructor() {
    hidden(this, '_signal', new AbortSignal(BRAND));
  }
  get signal() { return this._signal; }
  abort(reason) { doAbort(this._signal, reason); }
}
tag(AbortController, 'AbortController');

// Milliseconds since this process started, with the sub-millisecond
// resolution the monotonic clock has.
const performance = {
  now() { return process.uptime() * 1000; },
  timeOrigin: Date.now() - process.uptime() * 1000,
  toJSON() { return { timeOrigin: this.timeOrigin, now: this.now() }; },
};

module.exports = {
  DOMException: DOMException,
  Event: Event,
  CustomEvent: CustomEvent,
  EventTarget: EventTarget,
  AbortSignal: AbortSignal,
  AbortController: AbortController,
  performance: performance,
};
";
}

// The `perf_hooks` module: the same performance object the global is.
str node_perf_hooks_source() {
    return "'use strict';
const performance = require('_webevents').performance;
module.exports = { performance: performance };
";
}

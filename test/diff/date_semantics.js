// Timezone-independent throughout: UTC accessors, Date.UTC, epoch millisecond
// values and ISO formatting. Local-time behaviour is only asserted where it
// must agree regardless of the zone.
const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// --- construction ---
T('from-ms', () => new Date(0).getTime());
T('from-ms-negative', () => new Date(-86400000).toISOString());
T('from-iso', () => new Date('2020-06-15T12:30:45.123Z').getTime());
T('from-iso-date-only', () => new Date('2020-06-15').getTime());
T('from-iso-no-ms', () => new Date('2020-06-15T00:00:00Z').getTime());
T('from-date', () => new Date(new Date(12345)).getTime());
T('from-invalid-string', () => new Date('nonsense').getTime());
T('from-nan', () => new Date(NaN).getTime());
T('from-undefined', () => new Date(undefined).getTime());
T('from-null', () => new Date(null).getTime());
T('from-bool', () => new Date(true).getTime());
T('utc-args', () => Date.UTC(2020, 5, 15, 12, 30, 45, 123));
T('utc-partial', () => [Date.UTC(2020), Date.UTC(2020, 0)]);
T('utc-no-args', () => Date.UTC());
T('utc-two-digit-year', () => new Date(Date.UTC(99, 0, 1)).getUTCFullYear());
T('utc-month-overflow', () => new Date(Date.UTC(2020, 12, 1)).toISOString());
T('utc-day-overflow', () => new Date(Date.UTC(2020, 0, 32)).toISOString());
T('utc-negative-month', () => new Date(Date.UTC(2020, -1, 1)).toISOString());
T('instanceof', () => [new Date(0) instanceof Date, typeof new Date(0)]);
T('ctor-name', () => new Date(0).constructor.name);

// --- UTC accessors ---
T('utc-getters', () => {
  const d = new Date(Date.UTC(2020, 5, 15, 12, 30, 45, 123));
  return [d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), d.getUTCDay(),
          d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds(), d.getUTCMilliseconds()];
});
T('utc-day-of-week', () => [0, 1, 2, 3, 4, 5, 6].map((i) => new Date(Date.UTC(2020, 0, 5 + i)).getUTCDay()));
T('leap-day', () => new Date(Date.UTC(2020, 1, 29)).toISOString());
T('non-leap-rollover', () => new Date(Date.UTC(2019, 1, 29)).toISOString());
T('century-leap', () => [new Date(Date.UTC(2000, 1, 29)).getUTCDate(), new Date(Date.UTC(1900, 1, 29)).getUTCMonth()]);
T('epoch-getters', () => { const d = new Date(0); return [d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), d.getUTCDay()]; });

// --- UTC setters ---
T('setUTCFullYear', () => { const d = new Date(0); d.setUTCFullYear(2020); return d.toISOString(); });
T('setUTCMonth-rollover', () => { const d = new Date(Date.UTC(2020, 0, 31)); d.setUTCMonth(1); return d.toISOString(); });
T('setUTCDate-rollover', () => { const d = new Date(Date.UTC(2020, 0, 1)); d.setUTCDate(32); return d.toISOString(); });
T('setUTCHours-extra-args', () => { const d = new Date(0); d.setUTCHours(1, 2, 3, 4); return d.toISOString(); });
T('setUTCMilliseconds', () => { const d = new Date(0); d.setUTCMilliseconds(1500); return d.toISOString(); });
T('setTime', () => { const d = new Date(0); const r = d.setTime(86400000); return [r, d.toISOString()]; });
T('setter-returns-time', () => { const d = new Date(0); return d.setUTCFullYear(1971); });
T('setter-nan-invalidates', () => { const d = new Date(0); d.setUTCFullYear(NaN); return d.getTime(); });
T('setUTCFullYear-on-invalid', () => { const d = new Date(NaN); d.setUTCFullYear(2020); return d.getUTCFullYear(); });

// --- ISO and JSON ---
T('toISOString', () => new Date(Date.UTC(2020, 5, 15, 12, 30, 45, 123)).toISOString());
T('toISOString-pads', () => new Date(Date.UTC(2020, 0, 1, 1, 2, 3, 4)).toISOString());
T('toISOString-year-0', () => new Date(Date.UTC(0, 0, 1)).toISOString());
T('toISOString-extended-year', () => new Date(Date.UTC(12345, 0, 1)).toISOString());
T('toISOString-invalid-throws', () => new Date(NaN).toISOString());
T('toJSON', () => new Date(0).toJSON());
T('toJSON-invalid', () => new Date(NaN).toJSON());
T('json-stringify', () => JSON.stringify({ d: new Date(0) }));
T('json-stringify-invalid', () => JSON.stringify({ d: new Date(NaN) }));

// --- parse ---
T('parse-iso-utc', () => Date.parse('2020-06-15T12:30:45.123Z'));
T('parse-iso-offset', () => Date.parse('2020-06-15T12:30:45+02:00'));
T('parse-iso-negative-offset', () => Date.parse('2020-06-15T10:30:45-02:00'));
T('parse-date-only', () => Date.parse('2020-06-15'));
T('parse-year-month', () => Date.parse('2020-06'));
T('parse-year-only', () => Date.parse('2020'));
T('parse-invalid', () => [Date.parse('nope'), Date.parse('')]);
T('parse-roundtrip', () => { const s = new Date(Date.UTC(2020, 5, 15, 1, 2, 3, 4)).toISOString(); return Date.parse(s) === Date.UTC(2020, 5, 15, 1, 2, 3, 4); });
T('parse-out-of-range', () => Date.parse('2020-13-01'));

// --- arithmetic and coercion ---
T('difference', () => new Date(2000) - new Date(1000));
T('unary-plus', () => +new Date(12345));
T('valueOf', () => new Date(12345).valueOf());
T('comparison', () => [new Date(1) < new Date(2), new Date(1) > new Date(2)]);
T('equality-by-identity', () => { const a = new Date(0); return [a === a, new Date(0) === new Date(0), +new Date(0) === +new Date(0)]; });
T('toPrimitive-number', () => new Date(5)[Symbol.toPrimitive]('number'));
T('toPrimitive-default-is-string', () => typeof new Date(0)[Symbol.toPrimitive]('default'));
T('invalid-arithmetic', () => +new Date(NaN));
T('now-type', () => typeof Date.now());

// --- limits ---
T('max-time', () => new Date(8640000000000000).toISOString());
T('min-time', () => new Date(-8640000000000000).toISOString());
T('beyond-max', () => new Date(8640000000000001).getTime());
T('fractional-ms', () => new Date(1.9).getTime());

// Legacy date strings. Only zone-explicit forms are asserted, so the result
// does not depend on the machine's timezone.
T('parse-rfc2822', () => Date.parse('Tue, 01 Jan 2020 00:00:00 GMT'));
T('parse-rfc2822-offset', () => Date.parse('Tue, 01 Jan 2020 00:00:00 +0200'));
T('parse-long-month', () => new Date(Date.parse('December 17, 1995 03:24:00 GMT')).toISOString());
T('parse-day-first', () => new Date(Date.parse('1 Jan 2020 GMT')).toISOString());
T('parse-month-year', () => new Date(Date.parse('Jan 2020 GMT')).toISOString());
T('parse-legacy-bad-day', () => Date.parse('Jan 32 2020 GMT'));
T('parse-legacy-garbage', () => Date.parse('nonsense'));

console.log(rows.join('\n'));

// Not asserted:
//   - a bare numeric string such as new Date('0') is read by node as a
//     two-digit year; tsmc leaves it invalid. Its value is local-midnight
//     anyway, so it could not be asserted here regardless.
//   - local-time behaviour generally: tsmc keeps every date in UTC and
//     getTimezoneOffset() is always 0, so a date-time string without an offset
//     reads as UTC rather than local. Real zone support would need the tz
//     database.

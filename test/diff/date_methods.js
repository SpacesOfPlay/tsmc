// Date: construction, parsing, the UTC accessors, arithmetic and formatting.
// Local-time behaviour is exercised only where it must agree regardless of the
// machine's zone (both engines run in the same one, but round trips are safer).

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

T('epoch-iso', () => new Date(0).toISOString());
T('from-millis', () => new Date(86400000).toISOString());
T('negative-millis', () => new Date(-86400000).toISOString());
T('getTime', () => [new Date(0).getTime(), new Date(1234).getTime(), +new Date(5)]);
T('valueOf', () => new Date(99).valueOf());
T('utc-static', () => Date.UTC(2020, 0, 2, 3, 4, 5, 6));
T('from-components-utc', () => new Date(Date.UTC(2020, 0, 2, 3, 4, 5)).toISOString());

T('parse-iso', () => Date.parse('2020-01-02T03:04:05.000Z'));
T('parse-iso-no-ms', () => Date.parse('2020-01-02T03:04:05Z'));
T('parse-date-only', () => Date.parse('2020-01-02'));
T('parse-invalid', () => String(Date.parse('nope')));
T('ctor-from-string', () => new Date('2020-01-02T03:04:05.000Z').toISOString());
T('invalid-date', () => [String(new Date('nope')), String(new Date('nope').getTime())]);
T('invalid-iso-throws', () => new Date(NaN).toISOString());

T('utc-getters', () => {
  const d = new Date(Date.UTC(2020, 5, 15, 10, 20, 30, 400));
  return [d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), d.getUTCHours(),
    d.getUTCMinutes(), d.getUTCSeconds(), d.getUTCMilliseconds(), d.getUTCDay()];
});
T('utc-day-of-week', () => [0, 1, 2, 3, 4, 5, 6].map((i) => new Date(Date.UTC(2020, 0, 5 + i)).getUTCDay()));
T('local-getters-round-trip', () => {
  const d = new Date(2020, 5, 15, 10, 20, 30);
  return [d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds()];
});
T('timezone-offset-type', () => typeof new Date(0).getTimezoneOffset());

T('setTime', () => { const d = new Date(0); d.setTime(1000); return d.getTime(); });
T('setUTCFullYear', () => { const d = new Date(0); d.setUTCFullYear(2000); return d.getUTCFullYear(); });
T('setUTCMonth', () => { const d = new Date(Date.UTC(2020, 0, 1)); d.setUTCMonth(5); return d.toISOString(); });
T('setUTCDate', () => { const d = new Date(Date.UTC(2020, 0, 1)); d.setUTCDate(15); return d.toISOString(); });
T('setUTCHours', () => { const d = new Date(0); d.setUTCHours(5); return d.toISOString(); });
T('setUTCMinutes', () => { const d = new Date(0); d.setUTCMinutes(30); return d.toISOString(); });
T('setUTCSeconds', () => { const d = new Date(0); d.setUTCSeconds(45); return d.toISOString(); });
T('setUTCMilliseconds', () => { const d = new Date(0); d.setUTCMilliseconds(250); return d.toISOString(); });
T('set-rollover', () => { const d = new Date(Date.UTC(2020, 0, 31)); d.setUTCMonth(1); return d.toISOString(); });
T('set-overflow-day', () => { const d = new Date(Date.UTC(2020, 0, 1)); d.setUTCDate(32); return d.toISOString(); });

T('arithmetic', () => new Date(1000) - new Date(0));
T('comparison', () => [new Date(1) < new Date(2), new Date(1) > new Date(2)]);
T('equality-by-value', () => [new Date(0).getTime() === new Date(0).getTime(), new Date(0) === new Date(0)]);
T('add-millis', () => new Date(new Date(0).getTime() + 3600000).toISOString());

T('toJSON', () => new Date(0).toJSON());
T('json-stringify', () => JSON.stringify({ d: new Date(0) }));
T('toISOString-ms', () => new Date(1234).toISOString());
T('toISOString-year', () => new Date(Date.UTC(1999, 11, 31, 23, 59, 59, 999)).toISOString());
T('toString-type', () => typeof new Date(0).toString());
T('toDateString-type', () => typeof new Date(0).toDateString());
T('toUTCString-type', () => typeof new Date(0).toUTCString());
T('toLocaleDateString-type', () => typeof new Date(0).toLocaleDateString());

T('leap-year', () => new Date(Date.UTC(2020, 1, 29)).toISOString());
T('non-leap-rollover', () => new Date(Date.UTC(2021, 1, 29)).toISOString());
T('year-boundary', () => new Date(Date.UTC(2019, 11, 31, 23, 59, 59)).toISOString());
T('far-future', () => new Date(Date.UTC(2100, 0, 1)).toISOString());
T('far-past', () => new Date(Date.UTC(1900, 0, 1)).toISOString());
T('two-digit-year', () => new Date(Date.UTC(99, 0, 1)).getUTCFullYear());

T('is-date', () => [new Date(0) instanceof Date, typeof new Date(0)]);
T('date-now-type', () => typeof Date.now());
T('date-now-progresses', () => Date.now() >= 0);
T('ctor-no-new-type', () => typeof Date());

console.log(rows.join('\n'));

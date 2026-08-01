// Date's UTC setters, and the ES2024 Set operations.
//
// Only the UTC setters are checked: the local ones read the machine's zone,
// which tsmc does not have. Nothing here depends on the current time.

const rows = [];
function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.join(',') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  rows.push(label + ' = ' + show(v));
}
const iso = (d) => (Number.isNaN(d.getTime()) ? 'Invalid Date' : d.toISOString());
const at = (y, m, d, h, mi, s, ms) => new Date(Date.UTC(y, m, d, h || 0, mi || 0, s || 0, ms || 0));

// --- setUTCFullYear ---------------------------------------------------------
T('year-simple', () => { const d = at(2020, 0, 15); d.setUTCFullYear(1999); return iso(d); });
T('year-month', () => { const d = at(2020, 0, 15); d.setUTCFullYear(1999, 5); return iso(d); });
T('year-month-day', () => { const d = at(2020, 0, 15); d.setUTCFullYear(1999, 5, 30); return iso(d); });
T('year-returns-time', () => { const d = at(2020, 0, 15); return d.setUTCFullYear(2021) === d.getTime(); });
T('year-leap-to-common', () => { const d = at(2020, 1, 29); d.setUTCFullYear(2021); return iso(d); });

// --- setUTCMonth ------------------------------------------------------------
T('month-simple', () => { const d = at(2020, 0, 15); d.setUTCMonth(6); return iso(d); });
T('month-overflow', () => { const d = at(2020, 0, 15); d.setUTCMonth(12); return iso(d); });
T('month-negative', () => { const d = at(2020, 0, 15); d.setUTCMonth(-1); return iso(d); });
T('month-clamps-day', () => { const d = at(2020, 0, 31); d.setUTCMonth(1); return iso(d); });
T('month-with-day', () => { const d = at(2020, 0, 15); d.setUTCMonth(1, 5); return iso(d); });

// --- setUTCDate -------------------------------------------------------------
T('date-simple', () => { const d = at(2020, 0, 15); d.setUTCDate(20); return iso(d); });
T('date-zero', () => { const d = at(2020, 1, 15); d.setUTCDate(0); return iso(d); });
T('date-overflow', () => { const d = at(2020, 0, 15); d.setUTCDate(32); return iso(d); });
T('date-negative', () => { const d = at(2020, 1, 15); d.setUTCDate(-1); return iso(d); });
T('date-leap-29', () => { const d = at(2020, 1, 1); d.setUTCDate(29); return iso(d); });
T('date-nonleap-29', () => { const d = at(2021, 1, 1); d.setUTCDate(29); return iso(d); });

// --- time components --------------------------------------------------------
T('hours-simple', () => { const d = at(2020, 0, 15, 10); d.setUTCHours(3); return iso(d); });
T('hours-cascade', () => { const d = at(2020, 0, 15, 10); d.setUTCHours(3, 4, 5, 6); return iso(d); });
T('hours-overflow', () => { const d = at(2020, 0, 15, 10); d.setUTCHours(25); return iso(d); });
T('minutes-overflow', () => { const d = at(2020, 0, 15, 10); d.setUTCMinutes(75); return iso(d); });
T('seconds-overflow', () => { const d = at(2020, 0, 15, 10); d.setUTCSeconds(90); return iso(d); });
T('ms-overflow', () => { const d = at(2020, 0, 15, 10); d.setUTCMilliseconds(1500); return iso(d); });
T('ms-negative', () => { const d = at(2020, 0, 15, 10); d.setUTCMilliseconds(-1); return iso(d); });

// --- odd arguments ----------------------------------------------------------
T('nan-argument', () => { const d = at(2020, 0, 15); d.setUTCDate(NaN); return iso(d); });
T('fractional-date', () => { const d = at(2020, 0, 15); d.setUTCDate(20.9); return iso(d); });
T('string-argument', () => { const d = at(2020, 0, 15); d.setUTCMonth('3'); return iso(d); });
T('no-argument', () => { const d = at(2020, 0, 15); d.setUTCDate(); return iso(d); });
T('set-on-invalid', () => { const d = new Date(NaN); d.setUTCDate(5); return iso(d); });
T('setTime-revives', () => { const d = new Date(NaN); d.setTime(0); return iso(d); });
T('setTime-returns', () => { const d = at(2020, 0, 1); return d.setTime(86400000); });

// --- Set operations ---------------------------------------------------------
const S = (...xs) => new Set(xs);
const list = (s) => [...s].join(',');

T('union', () => list(S(1, 2, 3).union(S(3, 4))));
T('union-empty', () => list(S().union(S(1))));
T('intersection', () => list(S(1, 2, 3).intersection(S(2, 3, 4))));
T('intersection-order-smaller-other', () => list(S(1, 2, 3, 4).intersection(S(4, 2))));
T('difference', () => list(S(1, 2, 3).difference(S(2))));
T('symmetric-difference', () => list(S(1, 2).symmetricDifference(S(2, 3))));
T('is-subset', () => S(1, 2).isSubsetOf(S(1, 2, 3)));
T('is-subset-false', () => S(1, 5).isSubsetOf(S(1, 2, 3)));
T('is-superset', () => S(1, 2, 3).isSupersetOf(S(1, 2)));
T('is-disjoint', () => S(1, 2).isDisjointFrom(S(3, 4)));
T('is-disjoint-false', () => S(1, 2).isDisjointFrom(S(2, 3)));
T('result-is-set', () => S(1).union(S(2)) instanceof Set);
T('source-unchanged', () => { const a = S(1, 2); a.union(S(3)); return list(a); });
T('accepts-map', () => list(S(1, 2).intersection(new Map([[2, 'x'], [5, 'y']]))));
T('rejects-array', () => { try { S(1).union([2]); return 'accepted'; } catch (e) { return e.constructor.name; } });
T('rejects-number', () => { try { S(1).union(5); return 'accepted'; } catch (e) { return e.constructor.name; } });
T('string-elements', () => list(S('a', 'b').union(S('b', 'c'))));

console.log(rows.join('\n'));

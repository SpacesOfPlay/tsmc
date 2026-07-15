// Date: UTC accessors, Date.UTC, ISO formatting (timezone-independent).

const d = new Date(1609459200000); // 2021-01-01T00:00:00Z
console.log(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), d.getUTCDay());
console.log(d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds(), d.getUTCMilliseconds());
console.log(d.toISOString(), d.getTime());

const t = new Date(1234567890123);
console.log(t.getUTCFullYear(), t.getUTCHours(), t.getUTCMinutes(), t.getUTCSeconds());

console.log(Date.UTC(2021, 0, 1), Date.UTC(2021), Date.UTC(2021, 5, 15, 12, 30, 45));
console.log(new Date(Date.UTC(2021, 0, 1)).toISOString());
console.log(new Date(Date.UTC(2000, 11, 31, 23, 59, 59, 999)).toISOString());

// years 0..99 map to 1900..1999
console.log(new Date(Date.UTC(99, 0, 1)).getUTCFullYear());
console.log(new Date(Date.UTC(50, 6, 4)).toISOString());

// round-trip through JSON
console.log(JSON.stringify({ when: new Date(0) }));
console.log(typeof Date.now());

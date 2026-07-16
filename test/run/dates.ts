// Date formatting and parsing. The interpreter is UTC-only, so output
// is UTC (matches Node run with TZ=UTC). Golden values live in the
// .expected file rather than a differential test against a local zone.

const epoch = new Date(0);
console.log(epoch.toString());
console.log(epoch.toISOString());
console.log(epoch.toUTCString());
console.log(epoch.toDateString());
console.log(epoch.toTimeString());
console.log(epoch.toLocaleDateString());
console.log(epoch.toLocaleTimeString());
console.log(epoch.toLocaleString());

// ISO parsing round-trips through toISOString
console.log(new Date("2020-01-15").toISOString());
console.log(new Date("2020-06-15T10:30:00Z").toISOString());
console.log(new Date("2020-06-15T10:30:00.123Z").toISOString());
console.log(new Date("2020-06-15T10:30:00+02:00").toISOString());
console.log(Date.parse("2021-12-31T23:59:59Z"));

// afternoon time exercises the PM branch
console.log(new Date("2020-06-15T14:05:09Z").toLocaleTimeString());

// invalid input
console.log(new Date("not a date").toString());
console.log(new Date("2020-13-45").toString());
console.log(Number.isNaN(Date.parse("nope")));

// a recent timestamp, and Date used in string context (Symbol.toPrimitive)
const d = new Date("2023-11-14T22:13:20.000Z");
console.log(`${d}` === d.toString(), (d + "") === d.toString());
console.log(+d === d.getTime());

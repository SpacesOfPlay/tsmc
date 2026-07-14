const log = "ERROR: disk full at 14:32; WARN: low memory at 14:35";
const events = log.match(/(ERROR|WARN): (.+?) at (\d+:\d+)/g);
console.log(events!.length);

const re = /(\w+): (.+?) at (\d+:\d+)/g;
let m: RegExpExecArray | null;
while ((m = re.exec(log)) !== null) {
    console.log(m[1], "|", m[2], "|", m[3]);
}

const csv = "name,age,city";
console.log(csv.split(",").map((s) => s.toUpperCase()).join(" / "));
console.log("The year 2024 and month 01".replace(/\d+/g, (n) => "#" + n));
console.log(/^[a-z][a-z0-9_]*$/i.test("myVar_2"));

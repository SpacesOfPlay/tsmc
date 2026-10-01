// Property names that arrive as data (computed keys, JSON keys, Reflect
// and hasOwnProperty arguments) are freed once nothing uses them, and
// their ids are reused for new names. Objects that stay alive keep their
// properties, in order, through rounds of short-lived names.

function build(n: number): any {
  const o: any = {};
  for (let j = 0; j < n; j++) o['keep_' + n + '_' + j] = j * n;
  return o;
}

const kept: any[] = [];
for (let n = 1; n <= 40; n++) kept.push(build(n));
const parsed = JSON.parse('{"alpha_' + 7 + '":1,"beta_' + 8 + '":[2,3],"gamma_' + 9 + '":{"delta_' + 10 + '":4}}');
const g: any = globalThis;
g['global_' + 42] = 'held';
const want = kept.map((o) => JSON.stringify(o));
const wantParsed = JSON.stringify(parsed);

// A round of names used once: on objects that die at once, as lookups
// that miss, as JSON keys and as arguments to the reflective functions.
function churn(round: number) {
  const pad = 'x'.repeat(2000);
  let sum = 0;
  for (let i = 0; i < 400; i++) {
    const k = 'tmp_' + round + '_' + i;
    const t: any = {};
    t[k] = pad + i;
    sum += t[k].length;
    if (({} as any)['miss_' + round + '_' + i] === undefined) sum++;
    const j = JSON.parse('{"json_' + round + '_' + i + '":' + i + '}');
    sum += j['json_' + round + '_' + i];
    if (!Object.prototype.hasOwnProperty.call(t, 'own_' + round + '_' + i)) sum++;
    if (Reflect.has(t, k)) sum++;
  }
  return sum;
}

let total = 0;
for (let r = 0; r < 6; r++) total += churn(r);
console.log('churn', total);

let same = 0;
for (let i = 0; i < kept.length; i++) if (JSON.stringify(kept[i]) === want[i]) same++;
console.log('kept objects intact:', same, 'of', kept.length);
console.log('parsed intact:', JSON.stringify(parsed) === wantParsed);
console.log('global intact:', g['global_' + 42], ('global_' + 42) in g);
const o = kept[39];
console.log('lookup:', o['keep_40_0'], o['keep_40_39'], o['keep_40_40'], Object.keys(o).length);
console.log('in:', 'keep_40_39' in o, ('tmp_0_0') in o);
// a name freed earlier comes back as a new property without old values
const back: any = {};
back['tmp_0_0'] = 'new';
console.log('reused name:', back['tmp_0_0'], Object.keys(back).join(','));
delete o['keep_40_39'];
console.log('deleted:', 'keep_40_39' in o, Object.keys(o).length);

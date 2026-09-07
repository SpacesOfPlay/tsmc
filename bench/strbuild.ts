// A string built with +=, the way output and markup get assembled. Each
// step used to copy everything built so far; now the pieces share one
// growing buffer and are copied once.
let s = '';
for (let i = 0; i < 100000; i++) s += 'line ' + i + '\n';
let t = '';
for (let i = 0; i < 20000; i++) t += `<li>${i}</li>`;
console.log(s.length, t.length, s.charCodeAt(s.length - 2), t.endsWith('</li>'));

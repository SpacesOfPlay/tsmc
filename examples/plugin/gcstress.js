const demo = require('./demo.mc');
const keep = [];
for (let i = 0; i < 200; i++) {
  const o = demo.point(i, -i);
  for (let j = 0; j < 20; j++) keep.push({ s: 'junk' + i + '-' + j, arr: [1, 2, 3] });
  if (keep.length > 400) keep.length = 0;
  if (o.label !== 'point' || o.x !== i || o.y !== -i) {
    console.log('corrupt at', i, JSON.stringify(o));
    break;
  }
}
console.log('200 objects survived churn:', demo.hello());

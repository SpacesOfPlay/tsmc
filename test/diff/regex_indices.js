// The d flag: a match result carries [start, end] per group, and by name
// under indices.groups. Every offset a match reports is in UTF-16 units,
// including on subjects with multi-byte and astral characters.

const show = (m) => JSON.stringify({ index: m.index, m: [...m], indices: m.indices, groups: m.indices && m.indices.groups });

const re = /a(?<mid>b)?(c)/d;
console.log(re.hasIndices, re.flags);
console.log(show(re.exec('xxac')));
console.log(show(re.exec('xxabc')));

// no named groups: indices.groups is undefined, and no d flag: no indices
console.log(show(/a(b)/d.exec('zab')), /a(b)/.exec('zab').indices);

// non-ASCII subjects: index, indices and lastIndex are unit offsets
const s = 'å中😀bc😀';
const m = /b(c)/d.exec(s);
console.log(m.index, s.slice(m.indices[0][0], m.indices[0][1]), JSON.stringify(m.indices));
const g = /😀/gd;
const seen = [];
let mm;
while ((mm = g.exec(s)) !== null) seen.push([mm.index, g.lastIndex, mm.indices[0].join('-')]);
console.log(JSON.stringify(seen));

// sticky on a non-ASCII subject reads lastIndex in units
const y = /b/y;
y.lastIndex = 4;
console.log(y.exec(s) !== null, y.lastIndex);
y.lastIndex = 3;
console.log(y.exec(s), y.lastIndex);

// lastIndex past the end fails and resets
const past = /x?/g;
past.lastIndex = 10;
console.log(past.exec('abc'), past.lastIndex);

// match and matchAll hand the indices through
console.log(JSON.stringify('日本b'.match(/b/d).indices), [...'x日b日b'.matchAll(/b/gd)].map((x) => x.indices[0].join('-')).join(' '));
console.log([...'aåb'.matchAll(/./gu)].map((x) => x.index).join(','));

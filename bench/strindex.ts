// Unit-indexed loops over a non-ASCII string: the pattern a base64
// decoder or a byte-string scanner falls into. Each pass reads every unit
// once, forward or backward, through charCodeAt, indexing and split("").
const s = 'aÕ€😀b'.repeat(6000);   // 36,000 units, one to four bytes each
let acc = 0;
for (let i = 0; i < s.length; i++) acc = (acc + s.charCodeAt(i)) | 0;
for (let i = s.length - 1; i >= 0; i--) acc = (acc + s.charCodeAt(i)) | 0;
for (let i = 0; i < s.length; i++) acc = (acc + s[i].length) | 0;
const parts = s.split('');
for (let i = 0; i < parts.length; i++) acc = (acc + parts[i].charCodeAt(0)) | 0;
console.log(acc);

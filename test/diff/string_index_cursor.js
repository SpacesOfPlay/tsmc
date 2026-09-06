// Unit-indexed access to non-ASCII strings: forward, backward and random
// walks over charCodeAt, indexing, charAt, at, codePointAt, split(""),
// slice and spread, on text mixing one- to four-byte code points. Every
// value is printed, so the cursor that resumes lookups has to land on the
// same unit as a walk from the start would.

const atoms = ['a', 'é', '€', '😀', 'b', '𝄞', 'ü', 'c', 'ʁ', '中', '🎉', 'z'];
const s = atoms.join('').repeat(40);
const ascii = 'the quick brown fox '.repeat(50);
const wide = 'ᵁ'.repeat(300);
console.log('lengths', s.length, ascii.length, wide.length);

// a deterministic sequence of indices, some out of range
let seed = 12345;
const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };

for (const [name, t] of [['mixed', s], ['ascii', ascii], ['wide', wide]]) {
  let fwd = 0, bwd = 0, sum = 0;
  for (let i = 0; i < t.length; i++) fwd = (fwd * 31 + t.charCodeAt(i)) | 0;
  for (let i = t.length - 1; i >= 0; i--) bwd = (bwd * 31 + t.charCodeAt(i)) | 0;
  for (let k = 0; k < 500; k++) sum = (sum * 31 + t.charCodeAt(rnd(t.length + 3))) | 0;
  console.log(name, 'charCodeAt', fwd, bwd, sum, String(t.charCodeAt(t.length)), String(t.charCodeAt(-1)));

  let idx = '';
  for (let i = 0; i < t.length; i += 7) idx += t[i] + '|' + t.charAt(i) + '|' + t.at(-1 - i) + '|';
  console.log(name, 'index', idx.length, idx.slice(0, 60), String(t[t.length]), t.charAt(-1) === '');

  const cps = [];
  for (let i = 0; i < Math.min(t.length, 60); i++) cps.push(t.codePointAt(i));
  console.log(name, 'codePointAt', cps.join(','), String(t.codePointAt(t.length)));

  const parts = t.split('');
  console.log(name, 'split', parts.length, parts.join('') === t, parts.slice(0, 12).map((c) => c.charCodeAt(0)).join(','));

  let sl = '';
  for (let k = 0; k < 40; k++) { const a = rnd(t.length + 1), b = rnd(t.length + 1); sl += t.slice(a, b).length + ':' + t.substring(a, b).length + ','; }
  console.log(name, 'slice', sl);
  // a walk that alternates between the two ends
  let ends = 0;
  for (let i = 0; i < Math.min(t.length, 200); i++) ends = (ends * 31 + t.charCodeAt(i) + t.charCodeAt(t.length - 1 - i)) | 0;
  console.log(name, 'ends', ends);
}

// two strings interleaved keep separate positions
let inter = 0;
for (let i = 0; i < 300; i++) inter = (inter * 31 + s.charCodeAt(i * 3 % s.length) + wide.charCodeAt(i % wide.length)) | 0;
console.log('interleaved', inter);

// surrogate halves through slice and split, then re-indexed
const half = s.slice(3, 4);
console.log('half', half.length, half.charCodeAt(0), half.codePointAt(0), (half + s.slice(4, 5)).codePointAt(0), s.slice(3, 5) === '😀');
// halves rejoined are the whole again, however they meet
const hi = '😀'.slice(0, 1), lo = '😀'.slice(1);
console.log('rejoin', hi + lo === '😀', `${hi}${lo}` === '😀', [hi, lo].join('') === '😀', ('x' + hi + lo + 'y').length,
  (hi + lo).codePointAt(0), String.fromCharCode(0xd83d, 0xde00) === '😀', hi.concat(lo) === '😀', (hi + 'z' + lo).length);
const spread = { ...'a😀b' };
console.log('spread', Object.keys(spread).join(','), Object.values(spread).map((c) => c.charCodeAt(0)).join(','));
console.log('iterate', [...'a😀b'].length, Array.from('𝄞ü').map((c) => c.codePointAt(0)).join(','));

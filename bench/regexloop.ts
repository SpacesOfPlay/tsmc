// Regexes and short strings made in a loop: the compiled program of a
// literal or a repeated pattern is shared, and one-byte strings and
// small integers come from stock cells rather than the heap.
let hits = 0;
for (let i = 0; i < 3000; i++) {
  hits += new RegExp('^(\\d{' + (i % 9 + 1) + '})[a-z]+$', 'i').test('12abc') ? 1 : 0;
}
function tag(s: string): string {
  return s.replace(/(\w+)@(\w+)/g, (m, u, h) => `${h}:${u}`);
}
let out = '';
for (let i = 0; i < 20000; i++) out = tag('user' + i + '@host');
let chars = 0;
const text = 'the quick brown fox jumps over the lazy dog';
for (let i = 0; i < 20000; i++) chars += text[i % text.length].length + String(i).length;
console.log(hits, out, chars);

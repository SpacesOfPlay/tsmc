// without the u flag a pattern reads UTF-16 units: a class or . takes a
// whole BMP character, an astral one is two surrogates
const u = (s: string) => [...Array(s.length).keys()].map((i) => s.charCodeAt(i).toString(16)).join(',');
const e = 'x\u{1F338}y', q = 'Peggy’s', m = 'à\u0085 z';
console.log('c1 ' + u(q.replace(/[\u007F-\u009F]/g, '')));
console.log('c2 ' + u(e.replace(/[\u007F-\u009F]/g, '')));
console.log('c3 ' + u(m.replace(/[\u007F-\u009F]/g, '')));
console.log('c4 ' + u(q.replace(/[\u0000-\u001F\u007F-\u009F؜‎‏‪-‮⁦-⁩]/g, '')));
console.log('t1 ' + /[\u0080-ÿ]/.test('’'));
console.log('pair ' + u(e.replace(/[\uD800-\uDBFF][\uDC00-\uDFFF]/g, '#')));
console.log('hi ' + /\uD83C/.test(e) + ' ' + /🌸/.test(e));
console.log('dot ' + 'a\u{1F338}b'.match(/a.b/) + ' ' + ('a\u{1F338}b'.match(/a..b/) || ['no'])[0].length);
console.log('dotu ' + ('a\u{1F338}b'.match(/a.b/u) || ['no'])[0].length);
console.log('cls ' + u('a’b“c'.replace(/[’“]/g, '_')));
console.log('astral-cls ' + u(e.replace(/[🌸]/g, '_')));
console.log('idx ' + 'ab\u{1F338}cd'.search(/c/) + ' ' + ('ab\u{1F338}cd'.match(/c/) as RegExpMatchArray).index);
console.log('split ' + 'a’b’c'.split(/’/).join('|'));
console.log('sep ' + /a.b/.test('a b') + ' ' + /a.b/s.test('a b'));
console.log('neg ' + u('é中!'.replace(/[^a-z!]/g, '?')));
console.log('emoji ' + u('hi \u{1F44B}\u{1F3FD} there'.replace(/(?:[✀-➿]|(?:\uD83C[\uDDE6-\uDDFF]){2}|[\uD800-\uDBFF][\uDC00-\uDFFF])/g, '')));

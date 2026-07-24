// Identifiers outside ASCII. Beyond ASCII, an identifier character is
// decided by its Unicode general category: ID_Start is L* plus Nl, and
// ID_Continue adds Mn, Mc, Nd and Pc.

const café = 1;
const naïve = 2;
console.log('latin-1:', café, naïve);

const İ = 'dotted-I';
const ñ = 'n-tilde';
console.log('vars:', İ, ñ);
console.log('object keys:', JSON.stringify({ İ: 1, ñ: 2 }));

// A range of scripts.
const λ = 'lambda';
const Ω = 'omega';
const переменная = 'cyrillic';
const 変数 = 'japanese';
const 名前 = 'han';
console.log('scripts:', λ, Ω, переменная, 変数, 名前);

// ID_Continue characters that may not start an identifier.
const x١ = 'arabic-indic digit';
const _1café2 = 'digits inside';
console.log('continue:', x١, _1café2);

// Astral-plane letters (Lo above the BMP).
const 𐐀 = 'deseret';
console.log('astral:', 𐐀);

// Property access, shorthand, and computed keys.
const o = { café: 'prop', 名前: 'nm' };
console.log('member:', o.café, o.名前);
console.log('shorthand:', JSON.stringify({ café, λ }));
console.log('bracket:', o['café']);

// Functions, parameters, classes, and private names.
function función(パラメータ) { return パラメータ * 2; }
console.log('function:', función(21));

class Ünicode {
  #privé = 5;
  método() { return 'method'; }
  get valeur() { return this.#privé; }
  static créer() { return new Ünicode(); }
}
const u = Ünicode.créer();
console.log('class:', u.método(), u.valeur, u instanceof Ünicode);

// Destructuring and rebinding.
const { café: renamed } = o;
const [första, andra] = [10, 20];
console.log('destructure:', renamed, första, andra);

// ASCII identifiers and escapes are unaffected.
const $x = 1;
const _y = 2;
const abc = 3;
console.log('ascii:', $x, _y, abc);

// Non-identifier code points still work inside strings and quoted keys.
console.log('string:', '😀 emoji', { '😀': 'quoted' }['😀']);

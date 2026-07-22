#!/usr/bin/env node
// gen_unicode_props.mjs — regenerate src/regex_uniprops_data.mc.
//
// Emits the Unicode general-category run table (one run-length table that
// serves every category and category group) plus a range list per supported
// binary property, and the name-resolution functions that map a property
// name to either a category mask or a binary range list.
//
// The tables are derived by querying this node build's own regex engine
// rather than by parsing UnicodeData.txt, which keeps the generator small
// and dependency free and makes the tables agree by construction with the
// engine the differential suite compares against.
//
//   node tools/gen_unicode_props.mjs
//
// The hand-written lookup that turns these into RxRange lists lives in
// src/regex.mc and is NOT regenerated.

import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const MAX = 0x10FFFF;
const SUR_LO = 0xD800, SUR_HI = 0xDFFF;

// Category ids are positional; the emitted mask functions encode them, so
// nothing outside this file depends on the order.
const CATS = [
  'Lu', 'Ll', 'Lt', 'Lm', 'Lo',
  'Mn', 'Mc', 'Me',
  'Nd', 'Nl', 'No',
  'Pc', 'Pd', 'Ps', 'Pe', 'Pi', 'Pf', 'Po',
  'Sm', 'Sc', 'Sk', 'So',
  'Zs', 'Zl', 'Zp',
  'Cc', 'Cf', 'Co', 'Cs', 'Cn',
];

// Long names from UAX #44 PropertyValueAliases, plus the group letters.
const CAT_LONG = {
  Lu: 'Uppercase_Letter', Ll: 'Lowercase_Letter', Lt: 'Titlecase_Letter',
  Lm: 'Modifier_Letter', Lo: 'Other_Letter',
  Mn: 'Nonspacing_Mark', Mc: 'Spacing_Mark', Me: 'Enclosing_Mark',
  Nd: 'Decimal_Number', Nl: 'Letter_Number', No: 'Other_Number',
  Pc: 'Connector_Punctuation', Pd: 'Dash_Punctuation', Ps: 'Open_Punctuation',
  Pe: 'Close_Punctuation', Pi: 'Initial_Punctuation', Pf: 'Final_Punctuation',
  Po: 'Other_Punctuation',
  Sm: 'Math_Symbol', Sc: 'Currency_Symbol', Sk: 'Modifier_Symbol', So: 'Other_Symbol',
  Zs: 'Space_Separator', Zl: 'Line_Separator', Zp: 'Paragraph_Separator',
  Cc: 'Control', Cf: 'Format', Co: 'Private_Use', Cs: 'Surrogate', Cn: 'Unassigned',
};

const GROUPS = {
  L: ['Lu', 'Ll', 'Lt', 'Lm', 'Lo'],
  LC: ['Lu', 'Ll', 'Lt'],
  M: ['Mn', 'Mc', 'Me'],
  N: ['Nd', 'Nl', 'No'],
  P: ['Pc', 'Pd', 'Ps', 'Pe', 'Pi', 'Pf', 'Po'],
  S: ['Sm', 'Sc', 'Sk', 'So'],
  Z: ['Zs', 'Zl', 'Zp'],
  C: ['Cc', 'Cf', 'Co', 'Cs', 'Cn'],
};
const GROUP_LONG = {
  L: 'Letter', LC: 'Cased_Letter', M: 'Mark', N: 'Number',
  P: 'Punctuation', S: 'Symbol', Z: 'Separator', C: 'Other',
};

// Script values. node exposes no way to enumerate these, so the candidate
// list is spelled out and filtered to what this node build actually accepts;
// add new Unicode scripts here when regenerating against a newer node.
// Script is a partition (every code point has exactly one value), so it gets
// the same run-length treatment as general category. Script_Extensions is a
// different, multi-valued property and is deliberately not supported.
const SCRIPTS = ['Adlam','Ahom','Anatolian_Hieroglyphs','Arabic','Armenian','Avestan','Balinese','Bamum','Bassa_Vah','Batak','Bengali','Bhaiksuki','Bopomofo','Brahmi','Braille','Buginese','Buhid','Canadian_Aboriginal','Carian','Caucasian_Albanian','Chakma','Cham','Cherokee','Chorasmian','Common','Coptic','Cypro_Minoan','Cypriot','Cyrillic','Deseret','Devanagari','Dives_Akuru','Dogra','Duployan','Egyptian_Hieroglyphs','Elbasan','Elymaic','Ethiopic','Garay','Georgian','Glagolitic','Gothic','Grantha','Greek','Gujarati','Gunjala_Gondi','Gurmukhi','Gurung_Khema','Han','Hangul','Hanifi_Rohingya','Hanunoo','Hatran','Hebrew','Hiragana','Imperial_Aramaic','Inherited','Inscriptional_Pahlavi','Inscriptional_Parthian','Javanese','Kaithi','Kannada','Katakana','Kawi','Kayah_Li','Kharoshthi','Khitan_Small_Script','Khmer','Khojki','Khudawadi','Kirat_Rai','Lao','Latin','Lepcha','Limbu','Linear_A','Linear_B','Lisu','Lycian','Lydian','Mahajani','Makasar','Malayalam','Mandaic','Manichaean','Marchen','Masaram_Gondi','Medefaidrin','Meetei_Mayek','Mende_Kikakui','Meroitic_Cursive','Meroitic_Hieroglyphs','Miao','Modi','Mongolian','Mro','Multani','Myanmar','Nabataean','Nag_Mundari','Nandinagari','New_Tai_Lue','Newa','Nko','Nushu','Nyiakeng_Puachue_Hmong','Ogham','Ol_Chiki','Ol_Onal','Old_Hungarian','Old_Italic','Old_North_Arabian','Old_Permic','Old_Persian','Old_Sogdian','Old_South_Arabian','Old_Turkic','Old_Uyghur','Oriya','Osage','Osmanya','Pahawh_Hmong','Palmyrene','Pau_Cin_Hau','Phags_Pa','Phoenician','Psalter_Pahlavi','Rejang','Runic','Samaritan','Saurashtra','Sharada','Shavian','Siddham','SignWriting','Sinhala','Sogdian','Sora_Sompeng','Soyombo','Sundanese','Sunuwar','Syloti_Nagri','Syriac','Tagalog','Tagbanwa','Tai_Le','Tai_Tham','Tai_Viet','Takri','Tamil','Tangsa','Tangut','Telugu','Thaana','Thai','Tibetan','Tifinagh','Tirhuta','Todhri','Toto','Tulu_Tigalari','Ugaritic','Unknown','Vai','Vithkuqi','Wancho','Warang_Citi','Yezidi','Yi','Zanabazar_Square'];

// Binary properties: emitted name -> [aliases...]
const BINARY = {
  Alphabetic: ['Alpha'],
  White_Space: ['space'],
  Uppercase: ['Upper'],
  Lowercase: ['Lower'],
  ID_Start: ['IDS'],
  ID_Continue: ['IDC'],
  Assigned: [],
  ASCII: [],
  Any: [],
};

// --- derive the general-category of every code point ------------------------

const reAssigned = new RegExp('\\p{Assigned}', 'u');
const catRe = CATS.filter(c => c !== 'Cn').map(c => new RegExp('\\p{gc=' + c + '}', 'u'));
const catIdx = CATS.filter(c => c !== 'Cn');
const CN = CATS.indexOf('Cn');
const CS = CATS.indexOf('Cs');

const cat = new Uint8Array(MAX + 1).fill(CN);
for (let cp = 0; cp <= MAX; cp++) {
  if (cp >= SUR_LO && cp <= SUR_HI) { cat[cp] = CS; continue; }
  const s = String.fromCodePoint(cp);
  if (!reAssigned.test(s)) continue;          // stays Cn
  for (let i = 0; i < catRe.length; i++) {
    if (catRe[i].test(s)) { cat[cp] = CATS.indexOf(catIdx[i]); break; }
  }
}

// run-length encode: a run starts wherever the category changes
const starts = [];
const runCats = [];
for (let cp = 0; cp <= MAX; cp++) {
  if (cp === 0 || cat[cp] !== cat[cp - 1]) { starts.push(cp); runCats.push(cat[cp]); }
}

// --- binary property ranges -------------------------------------------------

function binaryRanges(name) {
  if (name === 'Any') return [[0, MAX]];
  if (name === 'ASCII') return [[0, 0x7F]];
  if (name === 'Assigned') {
    const out = [];
    for (let i = 0; i < starts.length; i++) {
      if (runCats[i] === CN) continue;
      const lo = starts[i], hi = (i + 1 < starts.length ? starts[i + 1] : MAX + 1) - 1;
      if (out.length && out[out.length - 1][1] === lo - 1) out[out.length - 1][1] = hi;
      else out.push([lo, hi]);
    }
    return out;
  }
  const re = new RegExp('\\p{' + name + '}', 'u');
  const out = [];
  for (let cp = 0; cp <= MAX; cp++) {
    const m = cp >= SUR_LO && cp <= SUR_HI ? false : re.test(String.fromCodePoint(cp));
    if (!m) continue;
    if (out.length && out[out.length - 1][1] === cp - 1) out[out.length - 1][1] = cp;
    else out.push([cp, cp]);
  }
  return out;
}

const binTables = {};
for (const name of Object.keys(BINARY)) binTables[name] = binaryRanges(name);

// --- script partition -------------------------------------------------------

const scNames = SCRIPTS.filter(n => {
  try { new RegExp('\\p{Script=' + n + '}', 'u'); return true; } catch { return false; }
});
const scUnknown = scNames.indexOf('Unknown');
const scRe = scNames.map(n => new RegExp('\\p{Script=' + n + '}', 'u'));
const script = new Uint8Array(MAX + 1).fill(scUnknown);
for (let cp = 0; cp <= MAX; cp++) {
  if (cp >= SUR_LO && cp <= SUR_HI) continue;   // Script=Unknown
  const s = String.fromCodePoint(cp);
  for (let i = 0; i < scRe.length; i++) { if (scRe[i].test(s)) { script[cp] = i; break; } }
}
const scStarts = [];
const scIds = [];
for (let cp = 0; cp <= MAX; cp++) {
  if (cp === 0 || script[cp] !== script[cp - 1]) { scStarts.push(cp); scIds.push(script[cp]); }
}

// --- emit -------------------------------------------------------------------

const hex = n => '0x' + n.toString(16).toUpperCase();

function wrap(items, perLine) {
  const lines = [];
  for (let i = 0; i < items.length; i += perLine) {
    lines.push('    ' + items.slice(i, i + perLine).join(', '));
  }
  return lines.join(',\n');
}

function maskOf(names) {
  let m = 0;
  for (const n of names) m |= 1 << CATS.indexOf(n);
  return m >>> 0;
}

const out = [];
out.push('// regex_uniprops_data.mc -- GENERATED, do not edit. Regenerate with');
out.push('// tools/gen_unicode_props.mjs. Unicode general-category run table plus');
out.push('// range lists for the supported binary properties, and the name');
out.push('// resolution both go through. The lookup that turns these into regex');
out.push('// character-class ranges lives in regex.mc.');
out.push('//');
out.push(`// Derived from node ${process.version}\'s regex engine (Unicode ${process.versions.unicode || 'unknown'}).`);
out.push(`// ${starts.length} category runs; ${scStarts.length} script runs over`);
out.push(`// ${scNames.length} scripts; ${Object.keys(BINARY).length} binary properties.`);
out.push('');
out.push('import str;');
out.push('');
out.push(`const i32 UNI_GC_RUNS = ${starts.length};`);
out.push('');
out.push('// Start code point of each run; the next run\'s start bounds it.');
out.push(`u32[${starts.length}] UNI_GC_START = {`);
out.push(wrap(starts.map(hex), 8));
out.push('};');
out.push('');
out.push('// General-category id of each run.');
out.push(`u8[${runCats.length}] UNI_GC_CAT = {`);
out.push(wrap(runCats.map(String), 20));
out.push('};');
out.push('');

for (const [name, ranges] of Object.entries(binTables)) {
  const flat = [];
  for (const [lo, hi] of ranges) { flat.push(hex(lo), hex(hi)); }
  out.push(`const i32 UNI_BIN_${name.toUpperCase()}_N = ${ranges.length};`);
  out.push(`u32[${flat.length}] UNI_BIN_${name.toUpperCase()} = {`);
  out.push(wrap(flat, 8));
  out.push('};');
  out.push('');
}

// name -> category mask
out.push('// A general-category name (short or long, single category or group) to a');
out.push('// bitmask of category ids. 0 means the name is not a general category.');
out.push('u32 uniprop_gc_mask(str n) {');
for (const c of CATS) {
  out.push(`    if str_equal(n, "${c}") || str_equal(n, "${CAT_LONG[c]}") { return ${maskOf([c])}; }`);
}
for (const g of Object.keys(GROUPS)) {
  out.push(`    if str_equal(n, "${g}") || str_equal(n, "${GROUP_LONG[g]}") { return ${maskOf(GROUPS[g])}; }`);
}
out.push('    return 0;');
out.push('}');
out.push('');

// script partition
out.push(`const i32 UNI_SC_RUNS = ${scStarts.length};`);
out.push('');
out.push('// Script is a partition like general category: run starts plus the');
out.push('// script id of each run.');
out.push(`u32[${scStarts.length}] UNI_SC_START = {`);
out.push(wrap(scStarts.map(hex), 8));
out.push('};');
out.push('');
out.push(`u8[${scIds.length}] UNI_SC_ID = {`);
out.push(wrap(scIds.map(String), 20));
out.push('};');
out.push('');
out.push('// A Script value name to its id, or -1 when unknown.');
out.push('i32 uniprop_script_id(str n) {');
for (let i = 0; i < scNames.length; i++) {
  out.push(`    if str_equal(n, "${scNames[i]}") { return ${i}; }`);
}
out.push('    return 0 - 1;');
out.push('}');
out.push('');

// name -> binary table
out.push('// A binary property name to its {lo,hi} range table. False if unknown.');
out.push('bool uniprop_binary(str n, u32** out, i32* cnt) {');
for (const [name, aliases] of Object.entries(BINARY)) {
  const names = [name, ...aliases];
  const cond = names.map(a => `str_equal(n, "${a}")`).join(' || ');
  out.push(`    if ${cond} {`);
  out.push(`        *out = &UNI_BIN_${name.toUpperCase()}[0];`);
  out.push(`        *cnt = UNI_BIN_${name.toUpperCase()}_N;`);
  out.push('        return true;');
  out.push('    }');
}
out.push('    return false;');
out.push('}');
out.push('');

const here = dirname(fileURLToPath(import.meta.url));
const dest = join(here, '..', 'src', 'regex_uniprops_data.mc');
writeFileSync(dest, out.join('\n'));
console.log(`wrote ${dest}: ${starts.length} gc runs, ` +
  `${scStarts.length} script runs over ${scNames.length} scripts, ` +
  Object.entries(binTables).map(([k, v]) => `${k}=${v.length}`).join(' '));

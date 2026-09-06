// highlight.js — TypeScript source to coloured spans, in the token colours
// of VS Code's Dark+ theme. A scanner, not a parser: strings, templates
// with nested expressions, comments, regex literals, numbers, keywords,
// types, functions and properties. Where the grammar is ambiguous it takes
// the likelier reading. Loads as a classic script and as a CommonJS module.

(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  root.TsmcHighlight = api;
})(typeof self !== 'undefined' ? self : globalThis, function () {
  'use strict';

  const words = (s) => new Set(s.split(' '));
  const CONTROL = words('if else for while do switch case default break continue return throw try catch finally yield await import export from as of with');
  const KEYWORD = words('const let var function class interface type enum namespace module new delete typeof instanceof void in this super extends implements static readonly public private protected abstract override async get set declare keyof infer is asserts satisfies true false null undefined');
  const TYPE = words('number string boolean any unknown never object symbol bigint');
  // a `/` after one of these starts a regex, not a division
  const REGEX_AFTER = words('typeof instanceof in new delete void');

  const SPACE = /\s+/y;
  const NUMBER = /0[xX][\da-fA-F_]+n?|0[bB][01_]+n?|0[oO][0-7_]+n?|(?:\d[\d_]*(?:\.[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?\d+)?n?/y;
  const IDENT = /[A-Za-z_$][\w$]*/y;
  const REGEX = /\/(?:[^/\\\n[]|\\.|\[(?:[^\]\\\n]|\\.)*\])+\/[a-z]*/y;
  const STRING1 = /'(?:[^'\\\n]|\\[^])*'?/y;
  const STRING2 = /"(?:[^"\\\n]|\\[^])*"?/y;
  const NEXT = /\s*(\S)/y;

  // Calls emit(cls, text) for every piece of src, in order, without gaps.
  // cls is one of: space punct comment str tpl num regex kw kwc type fn var.
  function tokenize(src, emit) {
    let last = null;
    const out = (cls, text) => {
      emit(cls, text);
      if (cls !== 'space' && cls !== 'comment') last = { cls, text };
    };
    const match = (re, i) => { re.lastIndex = i; const m = re.exec(src); return m ? m[0] : null; };
    const regexAllowed = () => !last
      || (last.cls === 'punct' && !')]}'.includes(last.text))
      || last.cls === 'kwc'
      || (last.cls === 'kw' && REGEX_AFTER.has(last.text));

    function classify(word, end) {
      const n = match(NEXT, end);
      const next = n ? n[n.length - 1] : '';
      const property = last && last.cls === 'punct' && last.text === '.';
      if (!property) {
        if (CONTROL.has(word)) return 'kwc';
        if (KEYWORD.has(word)) return 'kw';
        if (TYPE.has(word)) return 'type';
      }
      if (next === '(') return 'fn';
      if (!property && word[0] >= 'A' && word[0] <= 'Z') return 'type';
      return 'var';
    }

    // Scans from i. With stopAtBrace it returns at the `}` that closes a
    // template expression instead of consuming it.
    function scan(i, stopAtBrace) {
      let depth = 0;
      while (i < src.length) {
        const c = src[i];
        const c2 = src.substr(i, 2);
        let m;
        if ((m = match(SPACE, i))) { out('space', m); i += m.length; continue; }
        if (c2 === '//') {
          const e = src.indexOf('\n', i);
          const end = e < 0 ? src.length : e;
          out('comment', src.slice(i, end)); i = end; continue;
        }
        if (c2 === '/*') {
          const e = src.indexOf('*/', i + 2);
          const end = e < 0 ? src.length : e + 2;
          out('comment', src.slice(i, end)); i = end; continue;
        }
        if (c === "'" && (m = match(STRING1, i))) { out('str', m); i += m.length; continue; }
        if (c === '"' && (m = match(STRING2, i))) { out('str', m); i += m.length; continue; }
        if (c === '`') { i = template(i); continue; }
        if ((c >= '0' && c <= '9') || (c === '.' && src[i + 1] >= '0' && src[i + 1] <= '9')) {
          if ((m = match(NUMBER, i))) { out('num', m); i += m.length; continue; }
        }
        if (c === '@' && (m = match(IDENT, i + 1))) { out('fn', '@' + m); i += 1 + m.length; continue; }
        if ((m = match(IDENT, i))) { out(classify(m, i + m.length), m); i += m.length; continue; }
        if (c === '/' && regexAllowed() && (m = match(REGEX, i))) { out('regex', m); i += m.length; continue; }
        if (stopAtBrace) {
          if (c === '{') depth++;
          else if (c === '}') { if (depth === 0) return i; depth--; }
        }
        out('punct', c); i++;
      }
      return i;
    }

    function template(i) {
      out('str', '`'); i++;
      let run = '';
      const flush = () => { if (run) { out('str', run); run = ''; } };
      while (i < src.length) {
        const c = src[i];
        if (c === '`') { flush(); out('str', '`'); return i + 1; }
        if (c === '\\') { run += src.substr(i, 2); i += 2; continue; }
        if (c === '$' && src[i + 1] === '{') {
          flush();
          out('tpl', '${');
          const outer = last;
          last = null;
          i = scan(i + 2, true);
          last = outer;
          if (src[i] === '}') { out('tpl', '}'); i++; }
          continue;
        }
        run += c; i++;
      }
      flush();
      return i;
    }

    scan(0, false);
  }

  const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

  function highlight(src) {
    let html = '';
    tokenize(src, (cls, text) => {
      html += cls === 'space' || cls === 'punct' ? esc(text) : '<span class="' + cls + '">' + esc(text) + '</span>';
    });
    return html;
  }

  return { tokenize, highlight };
});

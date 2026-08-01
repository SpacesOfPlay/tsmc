// Markdown → HTML, and the directory index.
//
// markdown-it and js-yaml are the two npm dependencies this example exists to
// exercise: ordinary CommonJS packages resolved out of node_modules.

import fs from 'fs';
import path from 'path';
import MarkdownIt from 'markdown-it';
import yaml from 'js-yaml';

interface FrontMatter {
  title?: string;
  [key: string]: unknown;
}

const md = new MarkdownIt({ html: false, linkify: true, typographer: false });

const FRONT = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/;

export function splitFrontMatter(src: string): { front: FrontMatter; body: string } {
  const m = FRONT.exec(src);
  if (!m) return { front: {}, body: src };
  let front: FrontMatter = {};
  try {
    const parsed = yaml.load(m[1]);
    if (parsed && typeof parsed === 'object') front = parsed as FrontMatter;
  } catch (e) {
    // A malformed block shows as part of the body rather than failing the
    // request.
    return { front: {}, body: src };
  }
  return { front, body: src.slice(m[0].length) };
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"]/g, (c: string) => (
    c === '&' ? '&amp;' : c === '<' ? '&lt;' : c === '>' ? '&gt;' : '&quot;'
  ));
}

const STYLE = [
  'body{max-width:44rem;margin:2rem auto;padding:0 1rem;',
  'font:16px/1.6 system-ui,sans-serif;color:#222}',
  'pre{background:#f4f4f4;padding:.75rem;overflow-x:auto}',
  'code{background:#f4f4f4;padding:.1rem .3rem}',
  'pre code{background:none;padding:0}',
  'table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:.3rem .6rem}',
  'a{color:#0645ad}nav{color:#666;font-size:.9rem;margin-bottom:1.5rem}',
].join('');

function page(title: string, main: string): string {
  return [
    '<!doctype html>',
    '<html lang="en">',
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width,initial-scale=1">',
    '<title>' + escapeHtml(title) + '</title>',
    '<style>' + STYLE + '</style>',
    '<nav><a href="/">home</a></nav>',
    main,
    '</html>',
  ].join('\n');
}

export function renderMarkdown(src: string, fallbackTitle: string): string {
  const split = splitFrontMatter(src);
  const t = split.front.title;
  return page(typeof t === 'string' ? t : fallbackTitle, md.render(split.body));
}

export function renderIndex(dir: string, urlPath: string): string {
  const entries = fs.readdirSync(dir).sort();
  const items = entries.map((name: string) => {
    const isDir = fs.statSync(path.join(dir, name)).isDirectory();
    const prefix = urlPath.endsWith('/') ? urlPath : urlPath + '/';
    const href = prefix + encodeURIComponent(name);
    return '<li><a href="' + escapeHtml(href) + '">' + escapeHtml(name) + (isDir ? '/' : '') + '</a></li>';
  });
  const body = '<h1>' + escapeHtml(urlPath) + '</h1>\n<ul>\n' + items.join('\n') + '\n</ul>';
  return page('Index of ' + urlPath, body);
}

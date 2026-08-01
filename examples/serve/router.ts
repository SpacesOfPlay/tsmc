// URL → a path inside the content root, or a rejection.
//
// The traversal guard is the part that matters: a request may not escape the
// root, whether through `..` segments, an absolute path, or percent-encoded
// forms of either. The decision is made on the resolved absolute path rather
// than on the text of the URL, so an encoding trick has nothing to work with.

import fs from 'fs';
import path from 'path';

export interface Resolved {
  kind: 'file' | 'dir' | 'missing' | 'rejected';
  /** Absolute path on disk; empty when the request was rejected. */
  path: string;
  /** The requested path, decoded, for display. */
  urlPath: string;
}

export function decodePath(rawUrl: string): string | null {
  const q = rawUrl.indexOf('?');
  const withoutQuery = q < 0 ? rawUrl : rawUrl.slice(0, q);
  try {
    return decodeURIComponent(withoutQuery);
  } catch (e) {
    return null;   // malformed percent-encoding
  }
}

export function resolve(root: string, rawUrl: string): Resolved {
  const decoded = decodePath(rawUrl);
  if (decoded === null || decoded.indexOf('\0') >= 0) {
    return { kind: 'rejected', path: '', urlPath: rawUrl };
  }

  // path.join normalises `.` and `..` away; the containment test below is what
  // actually enforces the boundary.
  const full = path.resolve(path.join(root, decoded));
  const base = path.resolve(root);
  if (full !== base && full.indexOf(base + path.sep) !== 0) {
    return { kind: 'rejected', path: '', urlPath: decoded };
  }

  let stat;
  try {
    stat = fs.statSync(full);
  } catch (e) {
    return { kind: 'missing', path: full, urlPath: decoded };
  }
  return { kind: stat.isDirectory() ? 'dir' : 'file', path: full, urlPath: decoded };
}

/** A directory serves its index.md or index.html when one is present. */
export function indexOf(dir: string): string | null {
  const names = ['index.md', 'index.html'];
  for (const name of names) {
    const candidate = path.join(dir, name);
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

// Extension → content type. Hand-rolled rather than pulled from npm: the list
// a demo needs is short, and it keeps the dependency surface to the two
// packages this example exists to exercise.

const TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.wasm': 'application/wasm',
  '.pdf': 'application/pdf',
  '.xml': 'application/xml; charset=utf-8',
};

/** Types worth compressing: text, plus the structured formats that are text. */
const COMPRESSIBLE = /^(text\/|application\/(json|xml|wasm)|image\/svg)/;

export function contentTypeFor(ext: string): string {
  const t = TYPES[ext.toLowerCase()];
  return t === undefined ? 'application/octet-stream' : t;
}

export function isCompressible(contentType: string): boolean {
  return COMPRESSIBLE.test(contentType);
}

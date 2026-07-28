// Response construction: entity tags, conditional requests, compression.
//
// zlib here is sync-only and there is no fs.createReadStream, so a body is
// always a whole Buffer. Fine at this scale, and the reason for MAX_BYTES: a
// demo should refuse something enormous rather than pretend to stream it.

const crypto = require('crypto');
const zlib = require('zlib');
const mime = require('./mime.cts');

const MAX_BYTES = 8 * 1024 * 1024;

interface Encoded {
  bytes: Buffer;
  encoding: string | null;
}

/** Strong entity tag over the exact bytes served. */
function etagFor(bytes: Buffer): string {
  return '"' + crypto.createHash('sha256').update(bytes).digest('hex').slice(0, 32) + '"';
}

/** If-None-Match, limited to the forms a client actually sends. */
function matchesEtag(header: string | undefined, etag: string): boolean {
  if (!header) return false;
  if (header.trim() === '*') return true;
  return header.split(',').some((candidate: string) => {
    return candidate.trim().replace(/^W\//, '') === etag;
  });
}

function acceptsGzip(header: string | undefined): boolean {
  if (!header) return false;
  return header.split(',').some((part: string) => part.trim().split(';')[0] === 'gzip');
}

/** Compresses only when worth it: text-ish, and above a floor size. */
function encode(bytes: Buffer, contentType: string, wantGzip: boolean): Encoded {
  if (!wantGzip || bytes.length < 512 || !mime.isCompressible(contentType)) {
    return { bytes, encoding: null };
  }
  const gz = zlib.gzipSync(bytes);
  if (gz.length >= bytes.length) return { bytes, encoding: null };
  return { bytes: gz, encoding: 'gzip' };
}

module.exports = { etagFor, matchesEtag, acceptsGzip, encode, MAX_BYTES };

// crypto.createHmac across the supported digest set, vs Node.
const crypto = require('crypto');

const algos = ['md5', 'sha1', 'sha256', 'sha384', 'sha512'];

function hmac(algo, key, data, enc) {
  const h = crypto.createHmac(algo, key);
  h.update(data);
  return enc ? h.digest(enc) : h.digest();
}

// String key.
for (const algo of algos) {
  console.log(algo, 'strkey', hmac(algo, 'secret', 'message', 'hex'));
  console.log(algo, 'empty-msg', hmac(algo, 'secret', '', 'hex'));
  console.log(algo, 'empty-key', hmac(algo, '', 'message', 'hex'));
  console.log(algo, 'base64', hmac(algo, 'secret', 'message', 'base64'));
  console.log(algo, 'buffer', hmac(algo, 'secret', 'message').toString('hex'));
}

// Buffer key, including a key longer than the block (so K0 = H(key)).
for (const algo of algos) {
  const bufKey = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8, 0, 255]);
  console.log(algo, 'bufkey', hmac(algo, bufKey, 'message', 'hex'));
  const longKey = 'k'.repeat(200);   // > 128, exercises the hash-the-key path
  console.log(algo, 'longkey', hmac(algo, longKey, 'message', 'hex'));
}

// Chunked update must equal a single update.
for (const algo of algos) {
  const whole = hmac(algo, 'key', 'abcdefghij', 'hex');
  const h = crypto.createHmac(algo, 'key');
  h.update('abc');
  h.update(Buffer.from('def'));
  h.update('ghij');
  console.log(algo, 'chunked-ok', h.digest('hex') === whole);
}

// HS256-shaped: HMAC-SHA256 over a JWT signing input, base64url-ish check.
const signingInput = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0';
console.log('jwt', crypto.createHmac('sha256', 'jwt-secret').update(signingInput).digest('base64'));

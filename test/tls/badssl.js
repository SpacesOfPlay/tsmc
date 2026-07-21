// Manual (network-dependent): the secure-by-default trust posture against
// known-bad and known-good hosts. Not gated. Run: build/tsmc.exe test/tls/badssl.js
//
// badssl.com subdomains cover the classic failure modes; if a host does not
// speak TLS 1.3 the failure is transport-level, which still counts as
// "refused" but prints a different reason. The 1.1.1.1 cases pin the
// behavior on a host that definitely speaks 1.3: right SNI succeeds, wrong
// SNI must fail with a hostname mismatch.

const tls = require('tls');

function probe(name, opts) {
  return new Promise((resolve) => {
    const s = tls.connect(opts);
    const done = (msg) => { try { s.destroy(); } catch (_) {} resolve(msg); };
    s.on('secureConnect', () => done('CONNECTED'));
    s.on('error', (e) => done('refused: ' + e.message));
    setTimeout(() => done('timeout'), 15000);
  });
}

(async () => {
  const cases = [
    ['good (cloudflare 1.1.1.1, SNI one.one.one.one)',
      { host: '1.1.1.1', port: 443, servername: 'one.one.one.one' }],
    ['wrong SNI (cloudflare 1.1.1.1, SNI wrong.invalid)',
      { host: '1.1.1.1', port: 443, servername: 'wrong.invalid' }],
    ['expired.badssl.com', { host: 'expired.badssl.com', port: 443 }],
    ['wrong.host.badssl.com', { host: 'wrong.host.badssl.com', port: 443 }],
    ['self-signed.badssl.com', { host: 'self-signed.badssl.com', port: 443 }],
    ['untrusted-root.badssl.com', { host: 'untrusted-root.badssl.com', port: 443 }],
    // the badssl hosts are TLS 1.2-only, so even this cannot connect there;
    // prove the opt-out on a 1.3 host: hostname mismatch must be ignored
    ['wrong SNI with rejectUnauthorized:false (must connect)',
      { host: '1.1.1.1', port: 443, servername: 'wrong.invalid', rejectUnauthorized: false }],
  ];
  for (const [name, opts] of cases) {
    const r = await probe(name, opts);
    console.log(name, '->', r);
  }
})();

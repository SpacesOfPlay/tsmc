// Manual (network-dependent) end-to-end https test: the JS tls/https/fetch
// stack over the native TLS pump. Not gated (needs the internet). Run:
// build/tsmc.exe test/tls/https_fetch.js
//
// General trust is on by default (accept any cert but verify the handshake
// signature; chain/hostname NOT validated). For stronger trust, pin a key:
//   require('tls').setEcdsaPin('<64-hex SPKI-sha256>');
//
// A gated loopback https test needs picotls server mode (a later increment).

async function get(url) {
  try {
    const r = await fetch(url);
    const body = await r.text();
    console.log(url, '->', r.status, r.headers.get('content-type'), 'len', body.length);
  } catch (e) {
    console.log(url, 'ERROR', e.message);
  }
}

(async () => {
  await get('https://example.com/');       // ECDSA cert
  await get('https://www.google.com/');    // ECDSA cert
  await get('https://api.github.com/');    // RSA cert
})();

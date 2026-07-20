// Manual (network-dependent) end-to-end https test: the JS tls/https/fetch
// stack over the native TLS pump. Not gated (needs the internet + a live
// SPKI pin). Run: build/tsmc.exe test/tls/https_fetch.js
//
// A gated loopback https test needs picotls server mode (a later increment).

const tls = require('tls');
// example.com's ECDSA-P256 SPKI-sha256 pin (from picotls-minc example 10).
// If this drifts, the handshake is rejected — re-pin from a fresh cert.
tls.setEcdsaPin('b5d8f3ee8e63dbb30037ab85336fe928630649b4b204c4a2494d6be6ac382433');

(async () => {
  try {
    const res = await fetch('https://example.com/');
    const body = await res.text();
    console.log('status', res.status, res.ok);
    console.log('content-type', res.headers.get('content-type'));
    console.log('body length', body.length, 'has <h1>:', body.indexOf('<h1>') >= 0);
  } catch (e) {
    console.log('ERROR', e.message);
  }
})();

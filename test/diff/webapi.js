// The WHATWG fetch data types as globals: Headers, Request, Response.
// They are lazy globals -- the module behind them is only built when one is
// named -- so a script that never mentions them pays nothing.
// Compared byte-for-byte against Node.

console.log('typeof:', typeof Headers, typeof Request, typeof Response, typeof fetch);
console.log('on globalThis:', 'Headers' in globalThis, 'Request' in globalThis, 'Response' in globalThis);
console.log('identity:', globalThis.Headers === Headers, globalThis.Response === Response);

// --- Headers ---------------------------------------------------------------
const h = new Headers({ 'Content-Type': 'text/plain', 'X-A': '1' });
console.log('get:', h.get('content-type'), h.get('CONTENT-TYPE'), h.get('nope'));
console.log('has:', h.has('x-a'), h.has('x-b'));
h.set('X-B', '2');
h.append('X-A', '9');
console.log('set/append:', h.get('x-b'), h.get('x-a'));
h.delete('x-b');
console.log('delete:', h.has('x-b'));
const seen = [];
h.forEach((v, k) => seen.push(k + '=' + v));
console.log('forEach:', seen.join('|'));
console.log('keys:', [...h.keys()].join(','));
console.log('values:', [...h.values()].join(','));
console.log('entries:', JSON.stringify([...h.entries()]));
console.log('iterable:', JSON.stringify([...h]));
console.log('from pairs:', new Headers([['a', '1'], ['b', '2']]).get('a'));
console.log('from Headers:', new Headers(h).get('x-a'));
console.log('empty:', [...new Headers()].length);
console.log('instanceof:', h instanceof Headers);

// --- Response --------------------------------------------------------------
const r = new Response('hello', { status: 201, statusText: 'Created', headers: { 'X-T': 'v' } });
console.log('resp:', r.status, r.statusText, r.ok, r.headers.get('x-t'), r.bodyUsed);
console.log('resp default:', new Response().status, new Response().ok, new Response().statusText);
console.log('resp 404:', new Response('x', { status: 404 }).ok);
console.log('resp instanceof:', r instanceof Response, r.headers instanceof Headers);

// --- Request ---------------------------------------------------------------
const q = new Request('http://example.com/p?x=1', { method: 'post', headers: { 'X-Q': 'z' } });
console.log('req:', q.method, q.url, q.headers.get('x-q'));
console.log('req default:', new Request('http://e.com/').method);
console.log('req instanceof:', q instanceof Request);

// --- bodies (async) --------------------------------------------------------
(async () => {
  console.log('text:', await r.text(), 'bodyUsed:', r.bodyUsed);
  console.log('json:', JSON.stringify(await new Response(JSON.stringify({ a: 1, b: [2] })).json()));
  const ab = await new Response('abc').arrayBuffer();
  console.log('arrayBuffer:', ab.byteLength, [...new Uint8Array(ab)].join(','));
  console.log('req body:', await new Request('http://e.com/', { method: 'POST', body: 'payload' }).text());

  // a fetched Response is the same class as the global
  const http = require('http');
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain', 'X-Server': 'tsmc' });
    res.end('from server');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  const resp = await fetch('http://127.0.0.1:' + port + '/hi');
  console.log('fetched:', resp.status, resp.ok, await resp.text());
  console.log('fetched headers:', resp.headers.get('x-server'), resp.headers.get('X-SERVER'));
  console.log('fetched instanceof Response:', resp instanceof Response);
  console.log('fetched headers instanceof Headers:', resp.headers instanceof Headers);

  // fetch accepts a Request, and Headers as init.headers
  const resp2 = await fetch(new Request('http://127.0.0.1:' + port + '/via-request'));
  console.log('via Request:', resp2.status, await resp2.text());
  const resp3 = await fetch('http://127.0.0.1:' + port + '/h', { headers: new Headers({ 'X-C': '1' }) });
  console.log('via Headers init:', resp3.status);
  server.close();
})();

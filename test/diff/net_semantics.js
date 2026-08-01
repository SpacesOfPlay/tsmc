// net: the TCP layer under http, https and tls.
//
// Checks run one at a time, each tearing its server down before the next
// starts, so the output is ordered. Nothing prints an ephemeral port, and
// nothing depends on how a write is split into packets.

const net = require('net');

const rows = [];
function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}
async function T(label, fn) {
  let v;
  try {
    v = await Promise.race([
      Promise.resolve().then(fn),
      new Promise((r) => setTimeout(() => r('TIMEOUT'), 5000)),
    ]);
  } catch (e) {
    v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)) +
        (e && e.message ? ':' + e.message : '');
  }
  rows.push(label + ' = ' + show(v));
}

// Starts an echo-ish server, hands the port to `body`, then closes it.
function withServer(onConn, body) {
  return new Promise((resolve, reject) => {
    const server = net.createServer(onConn);
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      Promise.resolve()
        .then(() => body(port, server))
        .then((v) => server.close(() => resolve(v)), (e) => server.close(() => reject(e)));
    });
  });
}

async function main() {
  // --- server shape --------------------------------------------------------
  await T('address-shape', () => withServer(() => {}, (port, server) => {
    const a = server.address();
    return [typeof a.port, a.address, a.family].join('/');
  }));
  await T('listening-flag', () => withServer(() => {}, (port, server) => server.listening));
  await T('port-is-ephemeral', () => withServer(() => {}, (port) => port > 0 && port < 65536));

  // --- echo round trip -----------------------------------------------------
  await T('echo', () => withServer(
    (sock) => { sock.on('data', (d) => sock.write(d)); sock.on('end', () => sock.end()); },
    (port) => new Promise((res) => {
      let got = '';
      const c = net.connect(port, '127.0.0.1', () => { c.write('hello '); c.write('world'); });
      c.on('data', (d) => { got += d.toString(); if (got.length >= 11) c.end(); });
      c.on('close', () => res(got));
    })));

  await T('data-is-buffer', () => withServer(
    (sock) => { sock.on('data', (d) => sock.write(d)); },
    (port) => new Promise((res) => {
      const c = net.connect(port, '127.0.0.1', () => c.write('x'));
      c.on('data', (d) => { res(Buffer.isBuffer(d)); c.destroy(); });
    })));

  await T('setEncoding-gives-string', () => withServer(
    (sock) => { sock.on('data', (d) => sock.write(d)); },
    (port) => new Promise((res) => {
      const c = net.connect(port, '127.0.0.1', () => c.write('abc'));
      c.setEncoding('utf8');
      c.on('data', (d) => { res(typeof d); c.destroy(); });
    })));

  // --- lifecycle events ----------------------------------------------------
  await T('client-event-order', () => withServer(
    (sock) => { sock.end('bye'); },
    (port) => new Promise((res) => {
      const log = [];
      const c = net.connect(port, '127.0.0.1', () => log.push('connect'));
      c.on('data', () => log.push('data'));
      c.on('end', () => log.push('end'));
      c.on('close', () => { log.push('close'); res(log.join(',')); });
    })));

  await T('server-sees-connection', () => withServer(
    (sock) => { sock.write('greeting'); sock.end(); },
    (port) => new Promise((res) => {
      let got = '';
      const c = net.connect(port, '127.0.0.1');
      c.on('data', (d) => { got += d.toString(); });
      c.on('close', () => res(got));
    })));

  await T('write-callback-runs', () => withServer(
    (sock) => { sock.on('data', () => sock.end()); },
    (port) => new Promise((res) => {
      const c = net.connect(port, '127.0.0.1', () => {
        c.write('x', () => { res('called'); c.destroy(); });
      });
    })));

  await T('end-with-data', () => withServer(
    (sock) => { let s = ''; sock.on('data', (d) => { s += d; }); sock.on('end', () => sock.end(s)); },
    (port) => new Promise((res) => {
      let got = '';
      const c = net.connect(port, '127.0.0.1', () => c.end('final'));
      c.on('data', (d) => { got += d.toString(); });
      c.on('close', () => res(got));
    })));

  // --- two clients ---------------------------------------------------------
  await T('two-connections', () => withServer(
    (sock) => { sock.on('data', (d) => sock.write(d)); },
    (port) => new Promise((res) => {
      const seen = [];
      let done = 0;
      for (const tag of ['a', 'b']) {
        const c = net.connect(port, '127.0.0.1', () => c.write(tag));
        c.on('data', (d) => {
          seen.push(d.toString());
          c.destroy();
          if (++done === 2) res(seen.sort().join(','));
        });
      }
    })));

  // --- failure modes -------------------------------------------------------
  await T('refused-emits-error', () => new Promise((res) => {
    // port 1 on loopback: nothing listens there
    const c = net.connect(1, '127.0.0.1');
    c.on('error', (e) => res('error:' + (e && e.code ? e.code : 'no-code')));
    c.on('connect', () => { c.destroy(); res('unexpectedly connected'); });
  }));

  await T('destroy-then-write', () => withServer(
    (sock) => { sock.on('data', () => {}); },
    (port) => new Promise((res) => {
      const c = net.connect(port, '127.0.0.1', () => {
        c.destroy();
        try { c.write('after'); res('write returned'); }
        catch (e) { res('THROW:' + e.constructor.name); }
      });
    })));

  await T('destroyed-flag', () => withServer(
    (sock) => { sock.on('data', () => {}); },
    (port) => new Promise((res) => {
      const c = net.connect(port, '127.0.0.1', () => {
        const before = c.destroyed;
        c.destroy();
        res([before, c.destroyed].join('/'));
      });
    })));

  // --- server close --------------------------------------------------------
  await T('close-callback', () => new Promise((res) => {
    const server = net.createServer(() => {});
    server.listen(0, '127.0.0.1', () => {
      server.close(() => res('closed'));
    });
  }));

  await T('close-then-listening', () => new Promise((res) => {
    const server = net.createServer(() => {});
    server.listen(0, '127.0.0.1', () => {
      server.close(() => res(server.listening));
    });
  }));

  console.log(rows.join('\n'));
}

main();

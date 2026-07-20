// node_https.mc -- the `https` built-in: `http` over a TLS socket.
// Thin wrapper that flags the request `_tls` and defaults the port to 443;
// node_http's ClientRequest then connects via tls.connect. See
// doc/PLAN_M34_tls.md.

str node_https_source() {
    return "'use strict';
const http = require('http');

function toOpts(opts) {
  let o;
  if (typeof opts === 'string') {
    const u = new URL(opts);
    o = { host: u.hostname, port: u.port || 443, path: u.pathname + (u.search || '') };
  } else {
    o = {};
    for (const k in opts) o[k] = opts[k];
    if (!o.port) o.port = 443;
  }
  o._tls = true;
  if (!o.servername) o.servername = o.host || o.hostname;
  return o;
}

function request(opts, cb) { return http.request(toOpts(opts), cb); }
function get(opts, cb) { const r = request(opts, cb); r.end(); return r; }

module.exports = {
  request: request,
  get: get,
  Agent: function () {},
  globalAgent: {},
};
";
}

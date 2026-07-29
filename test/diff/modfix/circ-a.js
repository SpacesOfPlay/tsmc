// a requires b, which requires a back while a is still running: b sees the
// half-built exports, not the finished ones.
exports.stage = 'a-partial';
const b = require('./circ-b.js');
exports.stage = 'a-done';
exports.sawFromB = b.sawOfA;

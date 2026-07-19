// exports.foo attach + require a built-in + __dirname/__filename
const path = require("path");
exports.shout = (s) => s.toUpperCase() + "!";
exports.here = path.basename(__dirname);
exports.self = path.basename(__filename);

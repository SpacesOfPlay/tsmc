exports.name = "A";
const b = require("./b");
exports.bName = b.name;
exports.lateB = () => b.name;

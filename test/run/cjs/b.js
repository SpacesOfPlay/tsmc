exports.name = "B";
const a = require("./a");
exports.aNameAtLoad = a.name;   // set before a required b
exports.aBNameMissing = a.bName; // circular: not yet defined -> undefined

// runs inside nm/, so bare requires walk up to nm/node_modules
const pkgmain = require("pkgmain");
const pkgindex = require("pkgindex");
const scoped = require("@scope/tool");
const scopedSub = require("@scope/tool/sub");
const data = require("./data.json");
module.exports = () => [
  pkgmain.pad(42, 5),
  pkgindex.tag,
  scoped.name + "/" + scoped.dep,
  scopedSub.sub,
  data.n + ":" + data.list.join(","),
  require("pkgmain") === pkgmain,   // cache identity across the walk
].join(" | ");

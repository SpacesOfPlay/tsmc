// runs inside nm/, so bare requires walk up to nm/node_modules
const pkgmain = require("pkgmain");
const pkgindex = require("pkgindex");
const scoped = require("@scope/tool");
const scopedSub = require("@scope/tool/sub");
const data = require("./data.json");
// exports-map package: "." nested condition picks require; main ignored
const expkg = require("expkg");
const expExtra = require("expkg/extra");
function threw(f) { try { f(); return "no-throw"; } catch (e) { return "threw:" + (typeof e.code === "string"); } }
module.exports = () => [
  pkgmain.pad(42, 5),
  pkgindex.tag,
  scoped.name + "/" + scoped.dep,
  scopedSub.sub,
  data.n + ":" + data.list.join(","),
  require("pkgmain") === pkgmain,
  expkg.entry,
  expExtra.extra,
  threw(() => require("expkg/lib/hidden")),  // blocked by exports
].join(" | ");

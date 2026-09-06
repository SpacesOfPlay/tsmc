// A bare specifier names a package, never a file beside the importer.
// nm/shadow/ holds pkgindex.ts and pkgmain.ts, and the module there is
// itself named expkg.ts: each import in it must come from nm/node_modules,
// and the sibling files must stay unloaded.
import { report } from "./nm/shadow/expkg.ts";
console.log(await report());

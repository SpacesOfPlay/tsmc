// A TypeScript file may import a type, which has no binding at run time,
// so a name that resolves to nothing is not an error here.
import { Shape, Named, square } from "./mod/shape_types.ts";
import type { Shape as S2 } from "./mod/shape_types.ts";
const s: Shape = square(3);
const n: Named = { name: "ok" };
console.log(s.area(), n.name);

// `type` in an import list: a modifier before a name (a type-only
// import), and the name imported before `as`.
import { type as kind, as as word, type Shape } from "./mod/kinds";
const s: Shape = { sides: 3 };
console.log(kind(), "|", word, "|", s.sides);

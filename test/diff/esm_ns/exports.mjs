// A spread of export shapes, declared out of alphabetical order on purpose:
// a namespace reads its names in code unit order whatever order they arrive.
export let zeta = 0;
export const alpha = 'a';
export function mid() { return 'mid'; }
export class Cls {}
export default 42;
let renamed = 'r';
export { renamed as beta };
export function bump() { zeta++; }
export var Z_upper = 'upper';
export const _under = 'under';

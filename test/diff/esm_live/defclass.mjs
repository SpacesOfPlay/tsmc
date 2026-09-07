// A named default class is a declaration: the module can use the name,
// and a store to it changes the default export.
export default class Shape { static kind = 'shape'; }
export const made = new Shape();
export function replace() { Shape = class Square { static kind = 'square'; }; }

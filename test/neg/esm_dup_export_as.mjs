// expect: Duplicate export
var x, z;
export { x as y };
export { z as y };

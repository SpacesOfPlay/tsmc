// A namespace import exported under two names, next to a star re-export:
// the shape of a package index that also offers itself as `default`.
import * as inner from './inner.mjs';
export * from './inner.mjs';
export { inner as z, inner as default };
export * as grouped from './inner.mjs';

// an exported var that is never assigned still has its property
export var unassigned;

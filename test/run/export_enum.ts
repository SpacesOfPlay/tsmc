// An exported enum or namespace is filled by an IIFE that runs after the
// declaration. Exports copy the binding where they stand, so without a
// second mirror after that, the name goes out as undefined.
import { Colour, tag } from './mod/export_enum_dep.ts';
import * as ns from './mod/export_enum_dep.ts';

console.log('enum value:', Colour.Red, Colour.Blue);
console.log('enum reverse:', Colour[0]);
console.log('namespace value:', tag.name, tag.version);
console.log('through the namespace:', typeof ns.Colour, typeof ns.tag);
console.log('keys:', Object.keys(ns).sort().join(','));

// Sits beside its own node_modules so the package walk starts here.
import pkg from 'esmonly';
import { state } from 'esmonly';
import dual from 'dual';

export const report = [
  'esm-only package: ' + pkg.state,
  'named from it: ' + state,
  'same module twice: ' + (pkg.state === state),
  'dual takes the import branch: ' + dual.side,
];

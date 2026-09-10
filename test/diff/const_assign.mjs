// The same rule inside a module, where the strictness is implicit and an
// imported binding is immutable on the importing side.

import { b, counter } from './esm_live/state.mjs';
import * as ns from './esm_live/state.mjs';

const t = (label, f) => {
  try { console.log(label, '->', String(f())); }
  catch (e) { console.log(label, 'threw', e.constructor.name); }
};

t('import =', () => { b = 1; });
t('import +=', () => { counter += 1; });
t('import ++', () => { counter++; });
t('import still reads', () => b);
t('[b] = [2]', () => { [b] = [2]; });
t('namespace still reads', () => ns.b);

const c = 1;
t('module const', () => { c = 2; });

console.log('reached the end');

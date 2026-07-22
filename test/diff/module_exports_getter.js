// require() must read module.exports through the property path, so a module
// that redefines it as a getter (Object.defineProperty(module, 'exports',
// {get})) yields the getter's value rather than the original empty object.
// This is how ansi-styles (a chalk dependency) publishes its styles.
// Compared byte-for-byte against Node.

const styles = require('./module_exports_getter.helper.cjs');

console.log('count:', styles.count);
console.log('keys:', JSON.stringify(Object.keys(styles).sort()));
console.log('red:', JSON.stringify(styles.red));
console.log('hidden (non-enum own):', styles.hidden);
console.log('entries:', Object.entries(styles).filter(([k]) => k !== 'count').map(([k]) => k).sort().join(','));

// a second require returns a working export too (cache path reads via getter)
const again = require('./module_exports_getter.helper.cjs');
console.log('cached blue:', JSON.stringify(again.blue));

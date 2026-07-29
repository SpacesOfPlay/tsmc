// Drives the plugin next door. Run with a plugin-enabled build:
//
//   ./build.ps1 plugins
//   ./build/tsmc-plugins.exe examples/plugin/demo.js

const demo = require('./demo.mc');

console.log(demo.hello());
console.log('sum:', demo.sum(2, 3));
console.log('sum coerces:', demo.sum('4', 5));

const p = demo.point(1.5, -2);
console.log('point:', JSON.stringify(p));
console.log('point keys:', Object.keys(p).join(','));

// Ordinary JS values, so they behave like any other
console.log('spread:', { ...p, extra: true }.extra);
console.log('typeof native:', typeof demo.hello, demo.hello.name);

// The module cache holds a plugin like it holds a script
console.log('required twice:', require('./demo.mc') === demo);

// A native that throws unwinds into JS
try {
  demo.point(1);
} catch (e) {
  console.log('throw:', e.constructor.name + ':', e.message);
}

// A module that publishes its exports through a getter installed on `module`,
// the pattern ansi-styles uses. The loader must read module.exports through
// the property path so the getter runs. (.cjs so the diff runner's *.js glob
// does not execute this helper standalone.)
function assemble() {
  const out = { count: 0 };
  for (const name of ['red', 'green', 'blue']) {
    out[name] = { open: '<' + name + '>', close: '</' + name + '>' };
    out.count++;
  }
  // a non-enumerable own property, like ansi-styles' `codes`
  Object.defineProperty(out, 'hidden', { value: 99, enumerable: false });
  return out;
}

Object.defineProperty(module, 'exports', { enumerable: true, get: assemble });

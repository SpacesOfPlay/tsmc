// A CommonJS dependency of an ES module.
console.log('cjs body ran');
module.exports = {
  name: 'dep',
  add: (a, b) => a + b,
};

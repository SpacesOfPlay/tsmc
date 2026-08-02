// A required module whose functions are asked for their source after the
// module has finished loading. The source buffer has to outlive the load.

function helper(a, b) {
  return a + b;
}

const inner = (x) => x * 3;

class Shape {
  area(w, h) {
    return w * h;
  }
}

module.exports = { helper, inner, Shape };

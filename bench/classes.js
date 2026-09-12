// Class instantiation and method dispatch through two levels of inheritance,
// with a getter and a static. The shape stays monomorphic, which is what an
// engine with inline caches is best at and an interpreter cannot exploit.
class Shape {
  constructor(x, y) { this.x = x; this.y = y; }
  get sum() { return this.x + this.y; }
  scale(k) { this.x *= k; this.y *= k; return this; }
  static of(i) { return new Circle(i, i + 1, i % 7); }
}
class Circle extends Shape {
  constructor(x, y, r) { super(x, y); this.r = r; }
  area() { return this.r * this.r * 3; }
  scale(k) { super.scale(k); this.r *= k; return this; }
}
let acc = 0;
for (let i = 0; i < 700000; i++) {
  const c = Shape.of(i);
  acc = (acc + c.scale(2).area() + c.sum) | 0;
}
console.log(acc);

function Point(this: any, x: number, y: number) {
    this.x = x;
    this.y = y;
}
Point.prototype.dist2 = function (): number {
    return this.x * this.x + this.y * this.y;
};
const p = new (Point as any)(3, 4);
console.log(p.dist2());

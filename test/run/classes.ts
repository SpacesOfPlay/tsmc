class Shape {
    name: string;
    constructor(name: string) {
        this.name = name;
    }
    area(): number {
        return 0;
    }
    describe(): string {
        return this.name + ": " + this.area();
    }
}

class Rect extends Shape {
    constructor(private w: number, private h: number) {
        super("rect");
    }
    area(): number {
        return this.w * this.h;
    }
}

class Square extends Rect {
    constructor(side: number) {
        super(side, side);
    }
    get side(): number {
        return Math.sqrt(this.area());
    }
}

const shapes: Shape[] = [new Rect(3, 4), new Square(5)];
for (const s of shapes) {
    console.log(s.describe());
}
console.log((shapes[1] as Square).side);
console.log(shapes[0] instanceof Shape, shapes[1] instanceof Rect);

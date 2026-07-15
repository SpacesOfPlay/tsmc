import identity, { PI, mul } from "./math";
export class Circle {
    constructor(private r: number) {}
    area(): number {
        return mul(PI, mul(this.r, this.r));
    }
}
export const version = identity("1.0");

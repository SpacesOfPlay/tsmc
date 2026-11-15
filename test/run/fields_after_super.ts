// A derived class's fields and private methods land on the object super()
// returned, wherever the call is: a base that returns another object hands
// that object the fields (custom element upgrades rely on it).
let hand: any = {};
class Base { constructor() { return hand; } }
class Comma extends Base {
    x = 5;
    #m() { return 7; }
    constructor() { super(), this.d = 1; }
    get m() { return this.#m(); }
}
const c = new Comma();
console.log(c === hand, hand.x, hand.d);
Object.setPrototypeOf(hand, Comma.prototype);
console.log(hand.m);

class Plain { y = 0; }
class Late extends Plain {
    z = 2;
    constructor(flag: boolean) {
        const before = flag ? 1 : 0;
        super();
        console.log(before, this.z);
    }
}
new Late(true);

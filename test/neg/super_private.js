// expect: Unexpected private field
class C extends Object { #x; m() { return super.#x; } }

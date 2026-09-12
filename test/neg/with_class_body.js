// expect: Strict mode code may not include a with statement
class C {
    m() { with ({}) { return 1; } }
}

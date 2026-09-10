// expect: 'await' is a keyword
function outer() { class C { static { var await; } } }

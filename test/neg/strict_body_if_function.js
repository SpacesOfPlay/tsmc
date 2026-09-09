// expect: In strict mode code, functions can only be declared
function outer() { "use strict"; if (true) function f() {} }

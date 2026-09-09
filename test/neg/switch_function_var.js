// expect: has already been declared
switch (1) { case 1: function f() {} default: var f; }

// expect: Strict mode code may not include a with statement
'use strict';
const o = { a: 1 };
with (o) { a; }

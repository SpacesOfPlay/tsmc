// expect: Keyword must not contain escaped characters
'use strict';
var x = { l\u0065t } = { let: 1 };

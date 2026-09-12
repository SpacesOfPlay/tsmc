// expect: Lexical declaration cannot appear in a single-statement context
// `let [` begins no expression statement, so a line break does not make
// `let` an identifier here
with ({}) let
[a] = 0;

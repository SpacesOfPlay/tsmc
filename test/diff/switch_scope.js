// A switch's clauses share one lexical scope. Declarations in any clause are
// visible to the others, are in TDZ until their clause runs, and the scope is
// opened before the clause comparisons — the jump table branches straight into
// a body, so anything emitted after it would be skipped.

const out = [];
const r = (label, v) => out.push(label + '=' + v);

// let, const and class inside a clause.
switch (1) {
  case 1: {
    let a = 5;
    const b = 6;
    class C {}
    r('let', a);
    r('const', b);
    r('class', typeof C);
  }
}

// A binding declared in one clause is visible in a later one.
switch (1) {
  case 1:
    let shared = 'one';
  case 2:
    r('shared-across-clauses', shared);
}

// ...but is in TDZ if its clause did not run.
switch (2) {
  case 1:
    let skipped = 1;
    break;
  case 2:
    try { skipped; r('tdz', 'no-throw'); }
    catch (e) { r('tdz', e.constructor.name); }
}

// A function declaration is hoisted across the whole case block.
switch (2) {
  case 1:
    function hoisted() { return 7; }
    break;
  case 2:
    r('function-hoisted', typeof hoisted);
    r('function-callable', hoisted());
}

// The default clause is part of the same scope.
switch (99) {
  default:
    let d = 4;
    r('default-clause', d);
}

// var still reaches the enclosing function scope.
switch (1) {
  case 1:
    var v = 3;
}
r('var-escapes', v);

// Clause expressions are evaluated in order, and only until one matches.
let evaluated = 0;
function probe(n) { evaluated++; return n; }
switch (2) {
  case probe(1): r('unreachable', 1); break;
  case probe(2): r('matched-after', evaluated); break;
  case probe(3): r('unreachable', 3); break;
}

// Fallthrough and break still behave.
const seen = [];
switch (1) {
  case 1: seen.push('a');
  case 2: seen.push('b'); break;
  case 3: seen.push('c');
}
r('fallthrough', seen.join(','));

// Nested switches keep separate scopes.
switch (1) {
  case 1: {
    let m = 1;
    switch (2) {
      case 2: {
        let m2 = 2;
        r('nested', m + m2);
      }
    }
  }
}

// Breaking out of a clause that declared a binding.
switch (1) {
  case 1: {
    let b = 1;
    break;
  }
}
r('break-with-binding', 'done');

console.log(out.join('\n'));

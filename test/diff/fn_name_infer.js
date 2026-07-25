// Named evaluation: an anonymous function or class takes the name of the
// binding it is assigned to — in declarations, assignments, parameter and
// destructuring defaults, and object literal properties.

const out = [];
const r = (label, v) => out.push(label + '=' + JSON.stringify(v));

// Destructuring defaults, binding form.
{ var { a = function () {} } = {}; r('obj-fn', a.name); }
{ var { b = () => {} } = {}; r('obj-arrow', b.name); }
{ var { c = class {} } = {}; r('obj-class', c.name); }
{ var { d = function* () {} } = {}; r('obj-gen', d.name); }
{ var { e = async function () {} } = {}; r('obj-async', e.name); }
{ var { f = (function () {}) } = {}; r('obj-parenthesized', f.name); }
{ var [g = function () {}] = []; r('ary-fn', g.name); }
{ var [h = () => {}] = []; r('ary-arrow', h.name); }
{ var { i: j = function () {} } = {}; r('renamed', j.name); }
{ var { p: { q = function () {} } = {} } = {}; r('nested-obj', q.name); }
{ var [[s = function () {}]] = [[]]; r('nested-ary', s.name); }

// Destructuring defaults, assignment form.
{ let k; ({ k = function () {} } = {}); r('assign-obj', k.name); }
{ let l; ([l = function () {}] = []); r('assign-ary', l.name); }

// Parameter defaults, simple and destructured.
{ function fn({ m = function () {} }) { return m.name; } r('param-obj', fn({})); }
{ function fn([n = function () {}]) { return n.name; } r('param-ary', fn([])); }
{ function fn(t = function () {}) { return t.name; } r('param-simple', fn()); }

// Declarations and plain assignment.
{ const t = function () {}; r('declaration', t.name); }
{ let u; u = function () {}; r('assignment', u.name); }
{ let v; v = () => {}; r('assignment-arrow', v.name); }

// Object literal property values.
r('objlit-ident', ({ fn: function () {} }).fn.name);
r('objlit-arrow', ({ ar: () => {} }).ar.name);
r('objlit-string', ({ 'sk': function () {} })['sk'].name);
r('objlit-number', ({ 5: function () {} })[5].name);
r('objlit-class', ({ cv: class {} }).cv.name);

// A function that already has a name keeps it.
{ var { w = function keep() {} } = {}; r('named-kept', w.name); }
{ var { x = class Keep {} } = {}; r('class-named-kept', x.name); }

// A default that merely references an existing function does not rename it.
{ const base = function () {}; let y; ({ y = base } = {}); r('reference', y.name); }
{ function decl() {} let z; ({ z = decl } = {}); r('declaration-ref', z.name); }
{ let aa; ({ aa = (0, function () {}) } = {}); r('sequence', aa.name); }
{ let ab; ({ ab = [function () {}][0] } = {}); r('element', ab.name); }

// Member and index assignment targets do not name.
{ const o1 = {}; o1.k = function () {}; r('member-assign', o1.k.name); }
{ const o2 = {}; o2['m'] = function () {}; r('index-assign', o2.m.name); }

// A non-function default is untouched.
{ var { ac = 5 } = {}; r('non-function', ac); }

console.log(out.join('\n'));

// a var in a for-in or for-of head is the function's: a closure made
// before the loop reads it, and it keeps the last value after
function byClosure(o: any) { var p: any = {}; var s = function () { var v = o[f]; if (v == null) return 1; p[f] = v; }; for (var f in o) s(); return JSON.stringify(p) + ' after=' + f; }
console.log(byClosure({ a: 1, b: 2 }));
function ofClosure(arr: number[]) { var s = function () { return x; }; var r: number[] = []; for (var x of arr) r.push(s()); return r.join(',') + ' after=' + x; }
console.log(ofClosure([5, 6]));
function letOwn(arr: number[]) { var fs: (() => number)[] = []; for (let x of arr) fs.push(() => x); return fs.map((f) => f()).join(','); }
console.log(letOwn([7, 8]));
function mixed() { var seen: (() => number)[] = []; for (var i of [1, 2]) { let j = i * 10; seen.push(() => i + j); } return seen.map((f) => f()).join(',') + ' after=' + i; }
console.log(mixed());

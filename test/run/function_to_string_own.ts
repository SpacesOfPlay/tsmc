// A function's own toString wins in String(), concatenation and template
// literals, as for any object (localisation helpers return such functions).
const s: any = (e: any) => e;
s.toString = () => "hi";
console.log(String(s), "" + s, `${s}`);
console.log(String(function f(a: number) { return a; }), `${Math.max}`);

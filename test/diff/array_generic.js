// The mutating Array methods are generic over their receiver: the spec
// defines them via Get/Set/Delete on `this`, so they must work on an
// array-like or a Proxy (whose traps then fire). They previously refused any
// non-array receiver outright. Own-property existence must also account for
// array elements and `length`, which live outside the property table.
// Compared byte-for-byte against Node.

// --- mutating methods through a Proxy, with the trap sequence -------------
function traced(target) {
  const log = [];
  const p = new Proxy(target, {
    get(o, k) { log.push('get:' + String(k)); return Reflect.get(o, k); },
    set(o, k, v) { log.push('set:' + String(k) + '=' + String(v)); return Reflect.set(o, k, v); },
    deleteProperty(o, k) { log.push('del:' + String(k)); return Reflect.deleteProperty(o, k); },
  });
  return [p, log];
}

{
  const [p, log] = traced([1, 2, 3]);
  console.log('push ret:', p.push(4), JSON.stringify(p), '|', log.join(' '));
}
{
  const [p, log] = traced([1, 2, 3]);
  console.log('pop ret:', p.pop(), JSON.stringify(p), '|', log.join(' '));
}
{
  const [p, log] = traced([1, 2, 3]);
  console.log('shift ret:', p.shift(), JSON.stringify(p), '|', log.join(' '));
}
{
  const [p] = traced([1, 2, 3]);
  console.log('unshift ret:', p.unshift(0), JSON.stringify(p));
}
{
  const [p] = traced([1, 2, 3, 4]);
  console.log('splice del:', JSON.stringify(p.splice(1, 2)), JSON.stringify(p));
}
{
  const [p] = traced([1, 4]);
  console.log('splice ins:', JSON.stringify(p.splice(1, 0, 2, 3)), JSON.stringify(p));
}
{
  const [p] = traced([1, 2, 3]);
  console.log('splice rep:', JSON.stringify(p.splice(1, 1, 'x', 'y')), JSON.stringify(p));
}
{
  const [p] = traced([1, 2, 3]);
  p.reverse();
  console.log('reverse:', JSON.stringify(p));
}
{
  const [p] = traced([1, 2, 3, 4]);
  p.fill(0, 1, 3);
  console.log('fill:', JSON.stringify(p));
}

// --- mutating methods on a plain array-like object -------------------------
const al = { length: 2, 0: 'a', 1: 'b' };
console.log('al push ret:', Array.prototype.push.call(al, 'c'), 'len', al.length, al[2]);
console.log('al pop ret:', Array.prototype.pop.call(al), 'len', al.length);
const al2 = { length: 3, 0: 'x', 1: 'y', 2: 'z' };
console.log('al shift ret:', Array.prototype.shift.call(al2), 'len', al2.length, al2[0], al2[1]);
const al3 = { length: 1, 0: 'q' };
console.log('al unshift ret:', Array.prototype.unshift.call(al3, 'p'), al3[0], al3[1], al3.length);
const al4 = { length: 3, 0: 1, 1: 2, 2: 3 };
Array.prototype.reverse.call(al4);
console.log('al reverse:', al4[0], al4[1], al4[2]);

// (a primitive receiver is a documented divergence: node boxes it into a
// throwaway wrapper and silently succeeds, tsmc refuses loudly, so it is not
// asserted here)

// --- own-property existence over element storage ---------------------------
const hop = Object.prototype.hasOwnProperty;
const arr = [1, 2, 3];
console.log('hop idx str/num:', hop.call(arr, '0'), hop.call(arr, 0));
console.log('hop length:', hop.call(arr, 'length'));
console.log('hop oob:', hop.call(arr, '5'));
console.log('hop hole:', hop.call([1, , 3], '1'));
console.log('hasOwn:', Object.hasOwn(arr, '1'), Object.hasOwn(arr, 'length'));
console.log('in idx str/num:', '0' in arr, 0 in arr, '5' in arr, 'length' in arr);
console.log('str hop:', hop.call('abc', '0'), hop.call('abc', 'length'), hop.call('abc', '9'));
const ta = new Uint8Array([1, 2]);
console.log('ta hop:', hop.call(ta, '0'), hop.call(ta, '9'), hop.call(ta, 'length'));
function f() { return [hop.call(arguments, '0'), hop.call(arguments, 'length')].join(','); }
console.log('arguments hop:', f('q'));
console.log('obj hop:', hop.call({ x: 1 }, 'x'), hop.call({ x: 1 }, 'y'));

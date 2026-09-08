// yield* forwards what resumes the outer generator to the delegate:
// next() to its next, throw() to its throw, return() to its return. A
// delegate without a throw method is closed and the caller gets a
// TypeError; without a return method the outer generator returns what it
// was sent. The outer generator's own finally blocks run either way.

const at = (f) => { try { return JSON.stringify(f()); } catch (e) { return e.constructor.name + ': ' + e.message; } };

function* inner() {
  try { const x = yield 1; yield 'got ' + x; }
  catch (e) { yield 'caught ' + e; }
  finally { console.log('   inner finally'); }
}
function* outer() {
  try { const r = yield* inner(); yield 'after ' + r; }
  finally { console.log('   outer finally'); }
}
let g = outer(); g.next();
console.log('throw forwarded:', at(() => g.throw('boom')), at(() => g.next()));
g = outer(); g.next();
console.log('return forwarded:', at(() => g.return('bye')), at(() => g.next()));
g = outer(); g.next();
console.log('next input forwarded:', at(() => g.next('in')));

// a delegate that catches the throw and finishes: yield* evaluates to its return value
function* swallow() { try { yield 1; } catch (e) { return 'swallowed ' + e; } }
function* useSwallow() { const r = yield* swallow(); yield 'result ' + r; }
g = useSwallow(); g.next();
console.log('throw ends the delegate:', at(() => g.throw('x')));

// array iterators have neither method
function* overArray() { yield* [1, 2]; }
g = overArray(); g.next();
console.log('throw with no throw method:', at(() => g.throw(new Error('x'))), at(() => g.next()));
g = overArray(); g.next();
console.log('return with no return method:', at(() => g.return('r')), at(() => g.next()));

// a delegate whose return answers with its own value
const closable = {
  [Symbol.iterator]() {
    return {
      next() { return { value: 'v', done: false }; },
      return(v) { console.log('   closable return called'); return { value: 'closed ' + v, done: true }; },
    };
  },
};
function* overClosable() { const r = yield* closable; return r; }
g = overClosable(); g.next();
console.log('return via delegate:', at(() => g.return('R')));
g = overClosable(); g.next();
console.log('throw closes then TypeError:', at(() => g.throw(new Error('t'))));

// a delegate whose return keeps going: the outer generator keeps yielding
const stubborn = {
  [Symbol.iterator]() {
    let n = 0;
    return {
      next() { return { value: n++, done: false }; },
      return() { return { value: 'still here', done: false }; },
    };
  },
};
function* overStubborn() { yield* stubborn; }
g = overStubborn(); g.next();
console.log('return refused by delegate:', at(() => g.return('R')), at(() => g.next()));

// async generators delegate with the async protocol
async function* ainner() {
  try { yield 'a1'; yield 'a2'; }
  catch (e) { yield 'a caught ' + e; }
  finally { console.log('   async inner finally'); }
}
async function* aouter() { yield* ainner(); yield 'a after'; }
(async () => {
  let ag = aouter();
  await ag.next();
  console.log('async throw forwarded:', JSON.stringify(await ag.throw('aboom')), JSON.stringify(await ag.next()));
  ag = aouter();
  await ag.next();
  console.log('async return forwarded:', JSON.stringify(await ag.return('abye')), JSON.stringify(await ag.next()));
})();

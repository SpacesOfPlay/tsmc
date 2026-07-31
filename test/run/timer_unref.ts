// unref decides whether the loop keeps the process alive. A script cannot
// print that about itself, so this one just has to exit.
const beat = setInterval(() => console.log('should not print'), 5);
console.log('hasRef:', beat.hasRef());
beat.unref();
console.log('hasRef after unref:', beat.hasRef());

const held = setTimeout(() => console.log('reffed timer fired'), 10);
console.log('typeof handle:', typeof held);
console.log('clear accepts the object');
setTimeout(() => clearTimeout(held), 1);

const kept = setInterval(() => {}, 5);
kept.unref();
kept.ref();
kept.unref();
console.log('re-reffed then unreffed:', kept.hasRef());

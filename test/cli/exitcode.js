// Exit-status cases for the CLI smoke tests, one per argument. They cannot
// live in test/diff, where every script has to leave with 0.
const mode = process.argv[2];

if (mode === 'property') {
  // process.exitCode is what the process leaves with
  process.exitCode = 7;
} else if (mode === 'explicit') {
  // an argument to exit() beats the property
  process.exitCode = 7;
  process.exit(3);
} else if (mode === 'exit-no-arg') {
  // exit() with no argument takes the property
  process.exitCode = 5;
  process.exit();
} else if (mode === 'listener') {
  // an exit listener still gets to change it
  process.exitCode = 7;
  process.on('exit', () => { process.exitCode = 4; });
} else if (mode === 'caught') {
  // an uncaught exception that a listener takes is not a failure
  process.on('uncaughtException', () => {});
  setTimeout(() => { throw new Error('handled'); }, 1);
} else if (mode === 'uncaught') {
  setTimeout(() => { throw new Error('nobody catches this'); }, 1);
} else if (mode === 'rejection-caught') {
  process.on('unhandledRejection', () => {});
  Promise.reject(new Error('handled'));
}

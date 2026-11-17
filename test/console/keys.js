// keys.js: run by console_check.ps1 in a console of its own. Sets raw
// mode, takes the keys' bytes up to a q, writes them and what the
// terminal reported to the file named first, and writes a line with
// display attributes and characters beyond ASCII for the check to read
// back from the screen.
'use strict';
const fs = require('fs');
const out = process.argv[2];
const E = String.fromCharCode(27);
const got = [];
process.stdin.setRawMode(true);
process.stdin.on('data', (b) => {
  for (const x of b) got.push(x);
  if (b.indexOf(113) >= 0) {
    process.stdin.setRawMode(false);
    process.stdin.pause();
    process.stdout.write(E + '[1mBOLD' + E + '[22m ' + E + '[36mcyan' + E + '[39m • åäö done\n');
    fs.writeFileSync(out, JSON.stringify({
      bytes: got,
      tty: { stdin: process.stdin.isTTY === true, stdout: process.stdout.isTTY === true },
      columns: process.stdout.columns,
      rows: process.stdout.rows,
      raw: process.stdin.isRaw,
    }));
  }
});

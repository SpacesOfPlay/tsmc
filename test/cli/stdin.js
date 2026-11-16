// What standard input gives a script it is piped to: every byte, then
// 'end'. Run by the cli stage with its input fed.
process.stdin.setEncoding("utf8");
let got = "";
process.stdin.on("data", (chunk) => { got += chunk; });
process.stdin.on("end", () => {
  process.stdout.write("read " + JSON.stringify(got) + " tty " + (process.stdin.isTTY === true) + "\n");
});

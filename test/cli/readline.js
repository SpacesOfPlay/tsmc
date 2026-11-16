// readline on a pipe: a question's answer, then the lines, the last one
// without a line feed. Run by the cli stage with its input fed.
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const seen = [];
rl.question("name? ", (answer) => {
  seen.push("answer=" + answer);
  rl.on("line", (line) => seen.push("line=" + line));
  rl.on("close", () => { process.stdout.write("|" + seen.join("|") + "|terminal=" + rl.terminal + "\n"); });
});

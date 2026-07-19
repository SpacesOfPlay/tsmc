// Built-in `os` module. Values are host-specific but tsmc and node run on
// the same host in the harness, so they agree — the diff compares the two
// live outputs, nothing host-specific is committed. cpus() per-entry
// model/speed/times are placeholders (only the count is real), so those
// are checked by type, not value.
import os from "os";
import { platform, arch, EOL, homedir, tmpdir, hostname, type } from "node:os";

console.log(platform(), arch(), os.type(), os.endianness());
console.log(JSON.stringify(EOL), os.EOL === EOL);
console.log(os.homedir(), os.homedir() === homedir());
console.log(os.tmpdir(), os.hostname() === hostname());
console.log(os.cpus().length, typeof os.cpus()[0].model, typeof os.cpus()[0].speed, typeof os.cpus()[0].times.idle);

const u = os.userInfo();
console.log(u.username, u.homedir, u.uid, u.gid, u.shell);
console.log(typeof platform, typeof os, os.type() === type());

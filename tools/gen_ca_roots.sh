#!/usr/bin/env bash
# gen_ca_roots.sh — regenerate src/tls/ca_roots_data.mc from a Mozilla CA
# bundle (curl's cacert.pem). Emits the roots as one DER blob plus parallel
# offset/length index arrays. The lookup logic lives in the hand-written
# src/tls/ca_roots.mc and is NOT regenerated. Requires curl (or a local
# cacert.pem passed as $1) and node.
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
pem="${1:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if [ -z "$pem" ]; then
  pem="$work/cacert.pem"
  curl -fsS -o "$pem" https://curl.se/ca/cacert.pem
fi

node -e '
const fs = require("fs");
const pem = fs.readFileSync(process.argv[1], "utf8");
const asOf = (pem.match(/as of:\s*(.+?)\s*$/m) || [,"unknown"])[1];
const blocks = pem.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g) || [];
const ders = blocks.map(b => Buffer.from(b.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""), "base64"));
const blob = Buffer.concat(ders);
const offs = []; const lens = []; let o = 0;
for (const d of ders) { offs.push(o); lens.push(d.length); o += d.length; }

let out = "";
out += "// ca_roots_data.mc -- GENERATED, do not edit. Regenerate with\n";
out += "// tools/gen_ca_roots.sh. Trusted root CA certificates as one DER blob\n";
out += "// plus parallel offset/length index arrays. Lookup lives in\n";
out += "// ca_roots.mc.\n";
out += "//\n";
out += `// Source: Mozilla CA bundle via curl cacert.pem, as of: ${asOf}\n`;
out += `// ${ders.length} roots, ${blob.length} bytes.\n\n`;
out += `const i32 CA_ROOTS_COUNT = ${ders.length};\n\n`;

const arr = (name, vals) => {
  let s = `u32[${vals.length}] ${name} = {\n`;
  for (let i = 0; i < vals.length; i += 12) {
    s += "    " + vals.slice(i, i+12).join(", ") + (i+12 < vals.length ? "," : "") + "\n";
  }
  return s + "};\n\n";
};
out += arr("CA_ROOTS_OFF", offs);
out += arr("CA_ROOTS_LEN", lens);

out += `u8[${blob.length}] CA_ROOTS_DER = {\n`;
for (let i = 0; i < blob.length; i += 16) {
  const row = [];
  for (let j = i; j < Math.min(i+16, blob.length); j++) row.push("0x" + blob[j].toString(16).padStart(2, "0"));
  out += "    " + row.join(", ") + (i+16 < blob.length ? "," : "") + "\n";
}
out += "};\n";

fs.writeFileSync(process.argv[2], out);
console.error(`wrote ${ders.length} roots, ${blob.length} DER bytes`);
' "$pem" "$here/src/tls/ca_roots_data.mc"

echo "wrote $here/src/tls/ca_roots_data.mc"

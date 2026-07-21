#!/usr/bin/env bash
# gen_test_certs_real.sh — capture a live production certificate chain
# (leaf + intermediate) and embed it as test/helpers/x509_fixtures_real.mc,
# together with the capture time as X509_REAL_NOW. The chain-validation test
# verifies it against the bundled Mozilla store with `now` pinned to the
# capture time, so the test stays deterministic after the certs expire.
# Requires openssl, curl-era network access, and node.
set -e
host="${1:-example.com}"
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

openssl s_client -connect "$host:443" -servername "$host" -showcerts \
  </dev/null 2>/dev/null > chain.txt
now="$(date -u +%s)"

node -e '
const fs = require("fs");
const txt = fs.readFileSync("chain.txt", "utf8");
const blocks = txt.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g) || [];
if (blocks.length < 2) { console.error("expected >= 2 certs, got " + blocks.length); process.exit(1); }
const der = b => Buffer.from(b.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""), "base64");
const host = process.argv[1];
const now = process.argv[2];
const n = Math.min(blocks.length, 4);
let out = "// x509_fixtures_real.mc -- a captured production TLS chain, exactly as\n";
out += "// the server presented it, for validating against the bundled root\n";
out += `// store. Captured from ${host}:443; X509_REAL_NOW pins the validation\n`;
out += "// clock to the capture time so the test never rots. Regenerate with\n";
out += "// tools/gen_test_certs_real.sh (leaf SANs / chain shape may change --\n";
out += "// adjust test/unit/test_tls_chain.mc to match).\n\n";
out += `const i64 X509_REAL_NOW = ${now};\n`;
out += `const i32 X509_REAL_COUNT = ${n};\n\n`;
for (let k = 0; k < n; k++){
  const b = der(blocks[k]);
  const name = `X509_REAL_C${k}`;
  out += `u8[${b.length}] ${name} = {\n`;
  for (let i = 0; i < b.length; i += 16){
    const row = [];
    for (let j = i; j < Math.min(i+16, b.length); j++) row.push("0x" + b[j].toString(16).padStart(2, "0"));
    out += "    " + row.join(", ") + (i+16 < b.length ? "," : "") + "\n";
  }
  out += "};\n" + `const i32 ${name}_LEN = ${b.length};\n\n`;
}
fs.writeFileSync("x509_fixtures_real.mc", out);
' "$host" "$now"

cp x509_fixtures_real.mc "$here/test/helpers/x509_fixtures_real.mc"
echo "wrote $here/test/helpers/x509_fixtures_real.mc (host $host, now $now)"
echo "check the leaf SANs and update test/unit/test_tls_chain.mc if the"
echo "asserted hostnames or the chain shape changed."

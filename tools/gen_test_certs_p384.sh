#!/usr/bin/env bash
# gen_test_certs_p384.sh — regenerate the embedded P-384 test certificates
# (test/helpers/x509_fixtures_p384.mc) used by test/unit/test_tls_verify.mc:
#
#   p384_root       self-signed P-384 CA, ecdsa-with-SHA384
#   p384_leaf       P-384 key, signed by p384_root with SHA-384
#   p384_mixed      P-256 key, signed by p384_root with SHA-384
#   p384s512_leaf   P-384 key, signed by p384_root with SHA-512
#   p256_ca         self-signed P-256 CA, ecdsa-with-SHA384 (SHA-384 by a
#   p256s384_leaf   P-256 key, signed by p256_ca with SHA-384   P-256 key)
#
# Kept separate from tools/gen_test_certs.sh so regenerating this set never
# shifts the date pins in test/unit/test_x509.mc. No dates are asserted for
# these. Requires openssl and node.
set -e
export MSYS_NO_PATHCONV=1   # keep Git Bash from mangling the -subj argument
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

openssl ecparam -name secp384r1 -genkey -noout -out p384_root.key
openssl req -x509 -new -key p384_root.key -sha384 -days 7300 -out p384_root.pem \
  -subj "/C=US/O=tsmc test/CN=tsmc Test P384 Root" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectAltName=DNS:p384.example.test\n" > leaf.ext

openssl ecparam -name secp384r1 -genkey -noout -out p384_leaf.key
openssl req -new -key p384_leaf.key -sha384 -out p384_leaf.csr \
  -subj "/C=US/O=tsmc test/CN=p384.example.test"
openssl x509 -req -in p384_leaf.csr -CA p384_root.pem -CAkey p384_root.key \
  -CAcreateserial -sha384 -days 800 -out p384_leaf.pem -extfile leaf.ext

openssl ecparam -name prime256v1 -genkey -noout -out p384_mixed.key
openssl req -new -key p384_mixed.key -sha256 -out p384_mixed.csr \
  -subj "/C=US/O=tsmc test/CN=mixed.example.test"
openssl x509 -req -in p384_mixed.csr -CA p384_root.pem -CAkey p384_root.key \
  -CAcreateserial -sha384 -days 800 -out p384_mixed.pem -extfile leaf.ext

openssl ecparam -name secp384r1 -genkey -noout -out p384s512_leaf.key
openssl req -new -key p384s512_leaf.key -sha384 -out p384s512_leaf.csr \
  -subj "/C=US/O=tsmc test/CN=s512.example.test"
openssl x509 -req -in p384s512_leaf.csr -CA p384_root.pem -CAkey p384_root.key \
  -CAcreateserial -sha512 -days 800 -out p384s512_leaf.pem -extfile leaf.ext

openssl ecparam -name prime256v1 -genkey -noout -out p256_ca.key
openssl req -x509 -new -key p256_ca.key -sha384 -days 7300 -out p256_ca.pem \
  -subj "/C=US/O=tsmc test/CN=tsmc Test P256 SHA384 CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl ecparam -name prime256v1 -genkey -noout -out p256s384_leaf.key
openssl req -new -key p256s384_leaf.key -sha256 -out p256s384_leaf.csr \
  -subj "/C=US/O=tsmc test/CN=p256s384.example.test"
openssl x509 -req -in p256s384_leaf.csr -CA p256_ca.pem -CAkey p256_ca.key \
  -CAcreateserial -sha384 -days 800 -out p256s384_leaf.pem -extfile leaf.ext

for c in p384_root p384_leaf p384_mixed p384s512_leaf p256_ca p256s384_leaf; do
  openssl x509 -in $c.pem -outform DER -out $c.der
done

node -e '
const fs = require("fs");
const items = [
  ["X509_P384_ROOT","p384_root.der"],
  ["X509_P384_LEAF","p384_leaf.der"],
  ["X509_P384_MIXED","p384_mixed.der"],
  ["X509_P384_S512_LEAF","p384s512_leaf.der"],
  ["X509_P256_CA","p256_ca.der"],
  ["X509_P256_S384_LEAF","p256s384_leaf.der"],
];
let out = "// x509_fixtures_p384.mc -- embedded DER test certificates for the\n";
out += "// P-384 / mixed-curve signature tests. Regenerate with\n";
out += "// tools/gen_test_certs_p384.sh.\n\n";
for (const [name,file] of items){
  const b = fs.readFileSync(file);
  out += `u8[${b.length}] ${name} = {\n`;
  for (let i=0;i<b.length;i+=16){
    const row=[]; for(let j=i;j<Math.min(i+16,b.length);j++) row.push("0x"+b[j].toString(16).padStart(2,"0"));
    out += "    "+row.join(", ")+(i+16<b.length?",":"")+"\n";
  }
  out += "};\n" + `const i32 ${name}_LEN = ${b.length};\n\n`;
}
fs.writeFileSync("x509_fixtures_p384.mc", out);
'
# node runs with path conversion off; hand the result over with cp instead
cp x509_fixtures_p384.mc "$here/test/helpers/x509_fixtures_p384.mc"
echo "wrote $here/test/helpers/x509_fixtures_p384.mc"

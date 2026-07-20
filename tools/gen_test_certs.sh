#!/usr/bin/env bash
# gen_test_certs.sh — regenerate the embedded X.509 test chain used by
# test/unit/test_x509.mc (via test/helpers/x509_fixtures.mc).
#
# Produces a controlled chain with known field values:
#   root (RSA-2048, self-signed CA)
#     -> intermediate (ECDSA P-256 CA, pathlen:0, RSA-SHA256 signature)
#          -> leaf_ec  (ECDSA P-256, SAN incl. *.wild.example.test)
#          -> leaf_rsa (RSA-2048, SAN rsa.example.test)
#
# Then emits x509_fixtures.mc (DER as u8[] byte arrays). Copy the result to
# test/helpers/x509_fixtures.mc. Requires openssl and node.
#
# Note: the validity-date assertions in the test pin absolute unix seconds,
# so regenerating shifts notBefore/notAfter — update the constants in the
# test to the new openssl `-startdate`/`-enddate` values if you re-run this.
set -e
export MSYS_NO_PATHCONV=1   # keep Git Bash from mangling the -subj argument

# Work in a throwaway dir so private keys never land in the repo tree.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

openssl genrsa -out root.key 2048 2>/dev/null
openssl req -x509 -new -key root.key -sha256 -days 7300 -out root.pem \
  -subj "/C=US/O=tsmc test/CN=tsmc Test Root CA R1" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash"

openssl ecparam -name prime256v1 -genkey -noout -out inter.key
openssl req -new -key inter.key -sha256 -out inter.csr \
  -subj "/C=US/O=tsmc test/CN=tsmc Test Intermediate E1"
printf "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n" > inter.ext
openssl x509 -req -in inter.csr -CA root.pem -CAkey root.key -CAcreateserial \
  -sha256 -days 3650 -out inter.pem -extfile inter.ext

openssl ecparam -name prime256v1 -genkey -noout -out leaf_ec.key
openssl req -new -key leaf_ec.key -sha256 -out leaf_ec.csr \
  -subj "/C=US/O=tsmc test/CN=ecdsa.example.test"
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:ecdsa.example.test,DNS:*.wild.example.test\n" > leaf_ec.ext
openssl x509 -req -in leaf_ec.csr -CA inter.pem -CAkey inter.key -CAcreateserial \
  -sha256 -days 800 -out leaf_ec.pem -extfile leaf_ec.ext

openssl genrsa -out leaf_rsa.key 2048 2>/dev/null
openssl req -new -key leaf_rsa.key -sha256 -out leaf_rsa.csr \
  -subj "/C=US/O=tsmc test/CN=rsa.example.test"
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectAltName=DNS:rsa.example.test\n" > leaf_rsa.ext
openssl x509 -req -in leaf_rsa.csr -CA inter.pem -CAkey inter.key -CAcreateserial \
  -sha256 -days 800 -out leaf_rsa.pem -extfile leaf_rsa.ext

for c in root inter leaf_ec leaf_rsa; do openssl x509 -in $c.pem -outform DER -out $c.der; done

node -e '
const fs = require("fs");
const items = [["X509_ROOT","root.der"],["X509_INTER","inter.der"],
               ["X509_LEAF_EC","leaf_ec.der"],["X509_LEAF_RSA","leaf_rsa.der"]];
let out = "// x509_fixtures.mc -- embedded DER test certificates for the X.509\n";
out += "// parser unit tests. Regenerate with tools/gen_test_certs.sh.\n\n";
for (const [name,file] of items){
  const b = fs.readFileSync(file);
  out += `u8[${b.length}] ${name} = {\n`;
  for (let i=0;i<b.length;i+=16){
    const row=[]; for(let j=i;j<Math.min(i+16,b.length);j++) row.push("0x"+b[j].toString(16).padStart(2,"0"));
    out += "    "+row.join(", ")+(i+16<b.length?",":"")+"\n";
  }
  out += "};\n" + `const i32 ${name}_LEN = ${b.length};\n\n`;
}
fs.writeFileSync("x509_fixtures.mc", out);
'
dest="$(cd "$(dirname "$0")/.." && pwd)/test/helpers/x509_fixtures.mc"
cp "$work/x509_fixtures.mc" "$dest"
echo "wrote $dest"
echo "note: update the date constants in test/unit/test_x509.mc to the new"
echo "      -startdate/-enddate if you regenerated the chain."

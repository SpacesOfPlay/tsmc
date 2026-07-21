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
# plus path-validation attack fixtures (test/unit/test_tls_chain.mc):
#
#   rogue           CA:FALSE end-entity, signed by p384_root
#   victim          signed by rogue's key (a chain through it must fail)
#   mid_ca          CA:TRUE pathlen:0, signed by p384_root
#   sub_ca          CA:TRUE, signed by mid_ca (violates mid_ca's pathlen)
#   deep_leaf       signed by sub_ca
#   evil_leaf       signed by an "evil twin" CA carrying the SAME subject DN
#                   as the RSA test root of gen_test_certs.sh but a fresh
#                   key — an anchor matched by DN alone must still be refused
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

# --- path-validation attack fixtures ---

# rogue: an end-entity (CA:FALSE, no keyCertSign) that then signs "victim".
# A validator that skips basicConstraints would accept victim's chain.
openssl ecparam -name prime256v1 -genkey -noout -out rogue.key
openssl req -new -key rogue.key -sha256 -out rogue.csr \
  -subj "/C=US/O=tsmc test/CN=rogue.example.test"
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectAltName=DNS:rogue.example.test\n" > rogue.ext
openssl x509 -req -in rogue.csr -CA p384_root.pem -CAkey p384_root.key \
  -CAcreateserial -sha384 -days 800 -out rogue.pem -extfile rogue.ext

openssl ecparam -name prime256v1 -genkey -noout -out victim.key
openssl req -new -key victim.key -sha256 -out victim.csr \
  -subj "/C=US/O=tsmc test/CN=victim.example.test"
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectAltName=DNS:victim.example.test\n" > victim.ext
openssl x509 -req -in victim.csr -CA rogue.pem -CAkey rogue.key \
  -CAcreateserial -sha256 -days 800 -out victim.pem -extfile victim.ext

# mid_ca (pathlen:0) -> sub_ca -> deep_leaf: a valid-looking chain that
# violates mid_ca's pathLenConstraint.
openssl ecparam -name prime256v1 -genkey -noout -out mid_ca.key
openssl req -new -key mid_ca.key -sha256 -out mid_ca.csr \
  -subj "/C=US/O=tsmc test/CN=tsmc Test Mid CA pathlen0"
printf "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n" > mid_ca.ext
openssl x509 -req -in mid_ca.csr -CA p384_root.pem -CAkey p384_root.key \
  -CAcreateserial -sha384 -days 3650 -out mid_ca.pem -extfile mid_ca.ext

openssl ecparam -name prime256v1 -genkey -noout -out sub_ca.key
openssl req -new -key sub_ca.key -sha256 -out sub_ca.csr \
  -subj "/C=US/O=tsmc test/CN=tsmc Test Sub CA"
printf "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n" > sub_ca.ext
openssl x509 -req -in sub_ca.csr -CA mid_ca.pem -CAkey mid_ca.key \
  -CAcreateserial -sha256 -days 3650 -out sub_ca.pem -extfile sub_ca.ext

openssl ecparam -name prime256v1 -genkey -noout -out deep_leaf.key
openssl req -new -key deep_leaf.key -sha256 -out deep_leaf.csr \
  -subj "/C=US/O=tsmc test/CN=deep.example.test"
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectAltName=DNS:deep.example.test\n" > deep_leaf.ext
openssl x509 -req -in deep_leaf.csr -CA sub_ca.pem -CAkey sub_ca.key \
  -CAcreateserial -sha256 -days 800 -out deep_leaf.pem -extfile deep_leaf.ext

# evil twin: fresh key, subject DN byte-identical to the RSA test root
# ("tsmc Test Root CA R1" — same openssl, same string-type encoding).
openssl ecparam -name prime256v1 -genkey -noout -out evil_root.key
openssl req -x509 -new -key evil_root.key -sha256 -days 7300 -out evil_root.pem \
  -subj "/C=US/O=tsmc test/CN=tsmc Test Root CA R1" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl ecparam -name prime256v1 -genkey -noout -out evil_leaf.key
openssl req -new -key evil_leaf.key -sha256 -out evil_leaf.csr \
  -subj "/C=US/O=tsmc test/CN=evil-twin.example.test"
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectAltName=DNS:evil-twin.example.test\n" > evil_leaf.ext
openssl x509 -req -in evil_leaf.csr -CA evil_root.pem -CAkey evil_root.key \
  -CAcreateserial -sha256 -days 800 -out evil_leaf.pem -extfile evil_leaf.ext

for c in p384_root p384_leaf p384_mixed p384s512_leaf p256_ca p256s384_leaf \
         rogue victim mid_ca sub_ca deep_leaf evil_leaf; do
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
  ["X509_ROGUE","rogue.der"],
  ["X509_VICTIM","victim.der"],
  ["X509_MID_CA","mid_ca.der"],
  ["X509_SUB_CA","sub_ca.der"],
  ["X509_DEEP_LEAF","deep_leaf.der"],
  ["X509_EVIL_LEAF","evil_leaf.der"],
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

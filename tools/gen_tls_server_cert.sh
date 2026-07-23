#!/usr/bin/env bash
# gen_tls_server_cert.sh — regenerate the server certificate + key fixtures
# used by the loopback HTTPS server diff tests: an ECDSA-P256 pair
# (test/diff/https_server.{cert,key}.pem, used by https_server.js) and an
# RSA-2048 pair (test/diff/https_server_rsa.{cert,key}.pem, used by
# https_server_rsa.js).
#
# Both are self-signed for CN=localhost / SAN localhost, 127.0.0.1, dated far
# in the future so the fixtures do not expire. The diff tests' client uses
# rejectUnauthorized:false, so validity/hostname are not checked there — the
# long date just keeps the fixtures stable — but the server's
# CertificateVerify signature IS verified against the key, which is the point.
#
# Keys are unencrypted PEM (EC: SEC1 "BEGIN EC PRIVATE KEY"; RSA: PKCS#1
# "BEGIN RSA PRIVATE KEY"); tsmc's parser also accepts PKCS#8. Requires
# openssl (and node, to regenerate the RSA unit-test fixture below).
#
# Usage: tools/gen_tls_server_cert.sh   (writes into test/diff/)
#
# After regenerating the RSA pair, refresh the in-memory sign/verify unit-test
# key (test/helpers/rsa_key_fixture.mc) from the same key:
#
#   node -e 'const fs=require("fs"),c=require("crypto");
#     const jwk=c.createPrivateKey(fs.readFileSync(process.argv[1],"utf8")).export({format:"jwk"});
#     const b=s=>Buffer.from(s.replace(/-/g,"+").replace(/_/g,"/"),"base64");
#     const n=b(jwk.n),d=b(jwk.d),e=b(jwk.e).reduce((a,x)=>a*256+x,0);
#     const arr=(nm,buf)=>{let s="u8["+buf.length+"] "+nm+" = {\n";for(let i=0;i<buf.length;i+=12)
#       s+="    "+[...buf.slice(i,i+12)].map(x=>"0x"+x.toString(16).padStart(2,"0")).join(", ")+",\n";return s+"};\n";};
#     fs.writeFileSync("test/helpers/rsa_key_fixture.mc",
#       "const i32 RSA_TEST_KLEN = "+n.length+";\nconst u64 RSA_TEST_E = "+e+";\n\n"+arr("RSA_TEST_N",n)+"\n"+arr("RSA_TEST_D",d));
#   ' test/diff/https_server_rsa.key.pem
set -e
export MSYS_NO_PATHCONV=1

here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/test/diff"

# Run inside a throwaway dir with bare filenames so the mingw openssl build
# does not have to interpret git-bash-style paths.
work="$here/build/_certgen"
rm -rf "$work"; mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
cd "$work"

# EC P-256 key (SEC1 PEM) + a self-signed cert valid for ~100 years.
openssl ecparam -name prime256v1 -genkey -noout -out ec_key.pem
openssl req -new -x509 -key ec_key.pem -out ec_cert.pem \
  -days 36500 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

# RSA-2048 key (PKCS#1 PEM) + a matching self-signed cert.
openssl genrsa -out rsa_key.pem 2048
openssl req -new -x509 -key rsa_key.pem -out rsa_cert.pem \
  -days 36500 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

echo "EC cert:"; openssl x509 -in ec_cert.pem -noout -subject -ext subjectAltName
echo "RSA cert:"; openssl x509 -in rsa_cert.pem -noout -subject -ext subjectAltName

cp ec_key.pem   "$out/https_server.key.pem"
cp ec_cert.pem  "$out/https_server.cert.pem"
cp rsa_key.pem  "$out/https_server_rsa.key.pem"
cp rsa_cert.pem "$out/https_server_rsa.cert.pem"
cd "$here"
echo "wrote https_server.{cert,key}.pem and https_server_rsa.{cert,key}.pem in $out"
echo "NOTE: also refresh test/helpers/rsa_key_fixture.mc (see the header comment)."

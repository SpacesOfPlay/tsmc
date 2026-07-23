#!/usr/bin/env bash
# gen_tls_server_cert.sh — regenerate the ECDSA-P256 server certificate +
# key fixture used by the loopback HTTPS server diff test
# (test/diff/https_server.js and its .cert.pem / .key.pem siblings).
#
# A self-signed prime256v1 certificate for CN=localhost / SAN localhost,
# 127.0.0.1, dated far in the future so the fixture does not expire. The
# diff test's client uses rejectUnauthorized:false, so validity/hostname are
# not checked there — the long date just keeps the fixture stable — but the
# server's ECDSA CertificateVerify signature IS verified against this key,
# which is the point.
#
# The private key is emitted as unencrypted SEC1 PEM (BEGIN EC PRIVATE KEY);
# tsmc's key parser also accepts PKCS#8 (BEGIN PRIVATE KEY). Requires openssl.
#
# Usage: tools/gen_tls_server_cert.sh   (writes into test/diff/)
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
openssl ecparam -name prime256v1 -genkey -noout -out key.pem
openssl req -new -x509 -key key.pem -out cert.pem \
  -days 36500 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

echo "cert subject / dates / SAN:"
openssl x509 -in cert.pem -noout -subject -dates -ext subjectAltName

cp key.pem  "$out/https_server.key.pem"
cp cert.pem "$out/https_server.cert.pem"
cd "$here"
echo "wrote $out/https_server.cert.pem and .key.pem"

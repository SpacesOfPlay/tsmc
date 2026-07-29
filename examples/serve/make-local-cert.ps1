# Generates a local certificate authority and a server certificate signed by
# it, into .\local (gitignored). Trust the CA once and browsers stop warning
# about this server.
#
#   .\make-local-cert.ps1 [extra-hostname ...]
#
# The committed serve.cert.pem is left alone: it stays the zero-setup
# self-signed demo, and this is the opt-in trusted one.
#
# Why a CA rather than a self-signed certificate: a browser can only be told
# to trust an issuer, and a self-signed certificate is its own issuer, so
# trusting it means trusting exactly that file. A CA can reissue the server
# certificate whenever it expires without touching the trust store again.
#
# Both openssl invocations pass their own -config. Relying on the system
# openssl.cnf goes wrong two ways: some builds ship none at all, and those
# that do already add basicConstraints for -x509, so an -addext for it lands
# a SECOND copy -- and a certificate with a duplicate extension is rejected
# as malformed, by the verifier rather than by the tool that made it.
param([string[]]$Hostnames = @())

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force -Path local | Out-Null

$daysCa = 3650
$daysLeaf = 825        # browsers reject server certificates valid much longer

$sans = 'DNS:localhost,IP:127.0.0.1,IP:::1'
foreach ($h in $Hostnames) { $sans += ",DNS:$h" }

@'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = tsmc local dev CA
[ext]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
'@ | Set-Content -Path local\ca.cnf

@"
[req]
distinguished_name = dn
prompt = no
[dn]
CN = localhost
[ext]
subjectAltName = $sans
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
"@ | Set-Content -Path local\server.cnf

if (-not (Test-Path local\ca.key.pem)) {
    Write-Host 'creating a local CA in .\local'
    & openssl ecparam -name prime256v1 -genkey -noout -out local\ca.key.pem
    & openssl req -x509 -new -key local\ca.key.pem -sha256 -days $daysCa `
        -config local\ca.cnf -extensions ext -out local\ca.cert.pem
} else {
    Write-Host 'reusing the CA already in .\local'
}

& openssl ecparam -name prime256v1 -genkey -noout -out local\server.key.pem
& openssl req -new -key local\server.key.pem -config local\server.cnf -out local\server.csr
& openssl x509 -req -in local\server.csr -CA local\ca.cert.pem -CAkey local\ca.key.pem `
    -CAcreateserial -out local\server.cert.pem -days $daysLeaf -sha256 `
    -extfile local\server.cnf -extensions ext
Remove-Item local\server.csr -ErrorAction SilentlyContinue

# the pair is only useful if it actually chains
& openssl verify -CAfile local\ca.cert.pem local\server.cert.pem

Write-Host ''
& openssl x509 -in local\server.cert.pem -noout -subject -issuer -ext subjectAltName
Write-Host ''
Write-Host 'trust local\ca.cert.pem once (see README.md), then:'
Write-Host '  ..\..\build\tsmc.exe serve.cts --cert local\server.cert.pem --key local\server.key.pem'

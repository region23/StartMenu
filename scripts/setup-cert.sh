#!/usr/bin/env bash
# Create a stable self-signed code signing certificate so TCC grants
# (Accessibility, Screen Recording, Automation) persist across rebuilds.
# Without this, every rebuild changes the cdhash of the ad-hoc signed .app
# and macOS silently invalidates the Accessibility grant.

set -euo pipefail

CERT_NAME="StartMenu Dev Cert"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>&1 | grep -q "$CERT_NAME"; then
    echo "==> Cert '$CERT_NAME' already installed"
    exit 0
fi

echo "==> Creating self-signed code signing cert: $CERT_NAME"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CONF="$TMP/cert.conf"
KEY="$TMP/key.pem"
CRT="$TMP/cert.pem"
P12="$TMP/cert.p12"

cat > "$CONF" <<EOF
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_ext

[req_dn]
CN = $CERT_NAME

[v3_ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY" \
    -out "$CRT" \
    -days 3650 \
    -config "$CONF" 2>/dev/null

P12_PASS="startmenu"
openssl pkcs12 -export \
    -inkey "$KEY" \
    -in "$CRT" \
    -out "$P12" \
    -name "$CERT_NAME" \
    -passout "pass:$P12_PASS" \
    -certpbe PBE-SHA1-3DES \
    -keypbe PBE-SHA1-3DES \
    -macalg SHA1 \
    -legacy

security import "$P12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/productsign

# Allow codesign to use the private key without prompting for keychain password
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "==> Cert installed. Available codesigning identities:"
security find-identity -v -p codesigning "$KEYCHAIN"

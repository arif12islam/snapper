#!/bin/bash
# One-time setup: creates a local code-signing certificate so macOS remembers Snapper's permissions
# (Screen Recording, Accessibility) across updates. Safe to run again.
set -euo pipefail
NAME="Snapper Local Signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Signing identity already set up."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:snapper 2>/dev/null

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P snapper -T /usr/bin/codesign >/dev/null
echo "Trusting the certificate for code signing (macOS may ask for your password)..."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" || true

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Done. Builds are now signed with \"$NAME\"."
else
  echo "The certificate was created but is not trusted yet. Open Keychain Access, find \"$NAME\", set Trust > Code Signing to Always Trust, then run ./build.sh."
fi

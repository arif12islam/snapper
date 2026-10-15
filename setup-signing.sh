#!/bin/bash
# One-time setup of a stable code-signing identity.
#
# macOS forgets Screen Recording permission every time an app is signed differently. Signing every build with
# the same certificate (locally and on GitHub) keeps the permission and lets in-app updates install cleanly.
# The same certificate goes into two GitHub secrets so the release workflow signs identically.
set -euo pipefail
NAME="Snapper Local Signing"
DIR="$HOME/.snapper-signing"
P12="$DIR/snapper-signing.p12"
PASS="snapper-signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

have_identity() { security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; }

if have_identity && [ ! -f "$P12" ]; then
  echo "An older signing identity exists without an export. Replacing it (Screen Recording is asked for once more)."
  security delete-identity -c "$NAME" >/dev/null 2>&1 || true
fi

if ! have_identity; then
  mkdir -p "$DIR"
  chmod 700 "$DIR"
  cat > "$DIR/cert.cnf" <<CNF
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
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -config "$DIR/cert.cnf" 2>/dev/null
  openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$P12" -passout "pass:$PASS" 2>/dev/null
  security import "$P12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
  echo "Trusting the certificate for code signing (macOS may ask for your password)..."
  security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem" || true
  rm -f "$DIR/key.pem" "$DIR/cert.cnf"
fi

if have_identity; then
  echo "Local builds are now signed with \"$NAME\"."
else
  echo "The certificate was created but is not trusted yet. In Keychain Access, open \"$NAME\", set Trust > Code Signing to Always Trust, then run ./build.sh."
fi

# Secrets for the GitHub release workflow.
if [ -f "$P12" ]; then
  B64="$(base64 < "$P12" | tr -d '\n')"
  printf '%s' "$B64" | pbcopy 2>/dev/null || true
  echo
  echo "GitHub release signing"
  echo "Open: https://github.com/arif12islam/snapper/settings/secrets/actions and add two repository secrets."
  echo "  1. SIGNING_CERT_P12_BASE64   value: the long text now on your clipboard (also saved in $DIR/secret-base64.txt)"
  echo "  2. SIGNING_CERT_PASSWORD     value: $PASS"
  printf '%s' "$B64" > "$DIR/secret-base64.txt"
fi

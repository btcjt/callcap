#!/usr/bin/env bash
# Create the local code-signing certificate that build.sh signs with.
#
# Without it the app is signed ad-hoc, whose designated requirement is the
# binary's cdhash — so every rebuild silently revokes the Screen Recording
# grant and the toggle has to be re-ticked. A stable certificate makes the
# requirement "this bundle id, signed by this cert", which rebuilds preserve.
#
# Run once. Adding the trust setting shows a keychain prompt.
set -euo pipefail

NAME="${CALLCAP_IDENTITY:-Call Capture Local Signing}"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
  echo "'$NAME' already present — nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/req.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = $NAME
O = callcap
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -nodes -config "$WORK/req.cnf" >/dev/null 2>&1

# -legacy: macOS's security(1) cannot read OpenSSL 3's default PKCS#12 MAC.
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/id.p12" -passout pass:callcaplocal -name "$NAME" >/dev/null 2>&1

security import "$WORK/id.p12" -k ~/Library/Keychains/login.keychain-db \
  -P callcaplocal -A >/dev/null

# codesign only offers an identity it trusts for code signing.
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -qF "$NAME"; then
  echo "created '$NAME' — rebuild with ./build.sh, then grant permission once."
else
  echo "identity did not become valid; check the keychain prompt was accepted." >&2
  exit 1
fi

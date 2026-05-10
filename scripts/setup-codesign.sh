#!/bin/sh
set -eu

CERT_NAME="LG TV Control Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v | grep -q "$CERT_NAME"; then
  echo "Code signing cert already present: $CERT_NAME"
  exit 0
fi

OPENSSL=
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
  if [ -x "$candidate" ]; then
    OPENSSL="$candidate"
    break
  fi
done
if [ -z "$OPENSSL" ]; then
  echo "Error: OpenSSL 3 not found. Install with: brew install openssl@3" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = req_dn
x509_extensions = cert_ext
prompt = no

[req_dn]
CN = $CERT_NAME

[cert_ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

"$OPENSSL" req -new -x509 -nodes -newkey rsa:2048 \
  -keyout "$WORK/key.pem" \
  -out "$WORK/cert.pem" \
  -days 3650 \
  -config "$WORK/cert.cnf" >/dev/null 2>&1

"$OPENSSL" pkcs12 -export \
  -out "$WORK/cert.p12" \
  -inkey "$WORK/key.pem" \
  -in "$WORK/cert.pem" \
  -name "$CERT_NAME" \
  -password pass:tmppass \
  -legacy >/dev/null 2>&1

security import "$WORK/cert.p12" \
  -k "$KEYCHAIN" \
  -P "tmppass" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

security set-key-partition-list \
  -S "apple-tool:,apple:,codesign:" \
  -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "Code signing cert created: $CERT_NAME"
echo "You can now run ./build.sh to produce a stably-signed app."

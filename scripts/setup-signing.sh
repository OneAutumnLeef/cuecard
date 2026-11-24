#!/bin/bash
# One-time setup: creates a self-signed "MacTele Local Dev" code-signing identity in its own
# keychain file, so every build is signed the same way and macOS keeps granted permissions
# (microphone, screen recording) across rebuilds.
#
# It does not touch your login keychain, trust settings or keychain search list.
# The identity is only good for signing apps that run on this Mac.
set -euo pipefail

DIR="$HOME/Library/Application Support/MacTele/signing"
KC="$DIR/dev.keychain-db"
NAME="MacTele Local Dev"

if [ -f "$KC" ]; then
  echo "Signing keychain already exists at $KC"
  exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
PW="$(openssl rand -hex 24)"
printf '%s' "$PW" > "$DIR/password"
chmod 600 "$DIR/password"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/id.p12" -passout "pass:$PW"
cp "$WORK/cert.pem" "$DIR/cert.pem"

# `security create-keychain` adds the new keychain to the search list; put the list back afterwards.
OLD_LIST=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
  [ -n "$line" ] && OLD_LIST+=("$line")
done < <(security list-keychains -d user)

security create-keychain -p "$PW" "$KC"
security list-keychains -d user -s "${OLD_LIST[@]}"
security set-keychain-settings "$KC"            # never auto-lock
security unlock-keychain -p "$PW" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null

echo "Created \"$NAME\" in $KC"
echo "Certificate SHA-1: $(openssl x509 -in "$DIR/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2)"

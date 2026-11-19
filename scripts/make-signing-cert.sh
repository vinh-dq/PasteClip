#!/bin/sh
# Creates a self-signed code-signing certificate, "PasteClip Local Signing", in your login
# keychain. scripts/bundle.sh signs with it when it exists.
#
# Why: an ad-hoc signed app is identified by the hash of that exact build, so macOS forgets
# its Accessibility permission every time you rebuild. Signed with this certificate, every
# build has the same identity and keeps the permission.
#
# Undo: delete "PasteClip Local Signing" in Keychain Access (login keychain, My Certificates).
set -e
NAME="PasteClip Local Signing"

if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "\"$NAME\" already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cfg" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout pass:pasteclip
# -T lets codesign use the key without asking each time.
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P pasteclip -T /usr/bin/codesign >/dev/null

echo "Created \"$NAME\". Run ./scripts/bundle.sh to build a signed app."

#!/bin/bash
# One-time (idempotent) setup of a self-signed code-signing identity so that
# build_app.sh produces an app with a STABLE signing identity. Unlike ad-hoc
# signing, a stable identity lets macOS TCC persist Accessibility/Automation
# grants across rebuilds — no more re-authorizing every time the code changes.
#
# It creates a dedicated, separate keychain (does NOT touch your login
# keychain) holding one self-signed "Claude Command Bar Dev" certificate.
#
# Run once:  ./setup_signing.sh
set -euo pipefail

CERT_NAME="Claude Command Bar Dev"
KEYCHAIN="$HOME/Library/Keychains/claude-command-bar-dev.keychain-db"
KC_PASS="ccb-dev"      # password of the dedicated keychain (local dev only)

has_cert() { security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; }

if [ ! -f "$KEYCHAIN" ]; then
    echo "==> Creating dedicated keychain"
    security create-keychain -p "$KC_PASS" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"   # no auto-lock timeout
fi
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"

if ! has_cert; then
    echo "==> Generating self-signed code-signing certificate"
    TMP="$(mktemp -d)"
    cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null
    # Import the PEM cert and key separately (avoids openssl-3 PKCS12 MAC
    # incompatibility with macOS `security`). Keychain pairs them into an
    # identity automatically. -A + -T let codesign use the key non-interactively.
    security import "$TMP/cert.pem" -k "$KEYCHAIN" -A -T /usr/bin/codesign
    security import "$TMP/key.pem"  -k "$KEYCHAIN" -A -T /usr/bin/codesign
    # Avoid the keychain-password prompt on every codesign invocation.
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$TMP"
fi

# Ensure the keychain is on the user search list so codesign can find the identity.
if ! security list-keychains -d user | sed 's/"//g' | grep -q "claude-command-bar-dev"; then
    echo "==> Adding keychain to search list"
    OLD=$(security list-keychains -d user | sed 's/"//g' | xargs)
    security list-keychains -d user -s $OLD "$KEYCHAIN"
fi

echo "==> Available signing identity:"
security find-identity -p codesigning "$KEYCHAIN" | grep "$CERT_NAME" \
    || { echo "!! identity not found — signing will fail"; exit 1; }
echo "Done. Now run ./build_app.sh"

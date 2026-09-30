#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$DIR/certs"
mkdir -p "$CERTS_DIR"
cd "$CERTS_DIR"

echo "🔐 [1/3] Detecting Enterprise Root CA..."
# Check if a trusted Root CA already exists in sibling haproxy-edge folder to avoid duplicate keychain imports
if [ -f "$DIR/../haproxy-edge/root-ca.crt" ] && [ -f "$DIR/../haproxy-edge/root-ca.key" ]; then
  echo "   ...found existing trusted Root CA in haproxy-edge! Reusing it."
  cp "$DIR/../haproxy-edge/root-ca.crt" root-ca.crt
  cp "$DIR/../haproxy-edge/root-ca.key" root-ca.key
elif [ -f "$DIR/../haproxy-edge/certs/root-ca.crt" ] && [ -f "$DIR/../haproxy-edge/certs/root-ca.key" ]; then
  echo "   ...found existing trusted Root CA in haproxy-edge/certs! Reusing it."
  cp "$DIR/../haproxy-edge/certs/root-ca.crt" root-ca.crt
  cp "$DIR/../haproxy-edge/certs/root-ca.key" root-ca.key
elif [ ! -f "root-ca.key" ] || [ ! -f "root-ca.crt" ]; then
  echo "   ...generating fresh Root CA..."
  openssl req -x509 -new -nodes -newkey rsa:4096 \
    -keyout root-ca.key \
    -out root-ca.crt \
    -days 3650 \
    -subj "/C=AU/O=BrainyBots Enterprise/OU=Security/CN=BrainyBots Enterprise Root CA"
else
  echo "   ...using current root-ca.crt in certs/"
fi

echo "🔐 [2/3] Generating Backend Pod Private Key and CSR..."
openssl req -new -nodes -newkey rsa:2048 \
  -keyout passthrough.key \
  -out passthrough.csr \
  -subj "/C=AU/O=BrainyBots Enterprise/CN=passthrough-backend"

cat << 'EOF' > san.cnf
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.testapp-passthrough.apps.okd-sno.brainybots.cloud
EOF

echo "🔐 [3/3] Signing Backend Pod Certificate with Root CA..."
openssl x509 -req -in passthrough.csr \
  -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
  -out passthrough.crt -days 365 -extfile san.cnf

# Populate 01-tls-secret.yaml
CERT_B64=$(cat passthrough.crt | base64 | tr -d '\n')
KEY_B64=$(cat passthrough.key | base64 | tr -d '\n')

cat << EOF > "$DIR/01-tls-secret.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: passthrough-tls-secret
  namespace: demo-testapp-passthrough
type: kubernetes.io/tls
data:
  tls.crt: "$CERT_B64"
  tls.key: "$KEY_B64"
EOF

echo ""
echo "=========================================================================="
echo "✅ Backend Pod TLS Secret Populated into 01-tls-secret.yaml!"
echo "=========================================================================="

# Check if Root CA is already trusted in macOS Keychain
if command -v security &>/dev/null; then
  CA_SHA=$(openssl x509 -in root-ca.crt -noout -fingerprint | cut -d= -f2 | tr -d ':')
  if security find-certificate -a -c "BrainyBots Enterprise Root CA" -Z 2>/dev/null | grep -qi "$CA_SHA"; then
    echo "🎉 macOS Keychain Check: Root CA is ALREADY TRUSTED in your System Keychain!"
    echo "   Your browser will show the green padlock 🔒 automatically."
  else
    echo "🔒 Action Required for macOS (One Command for Green Padlock):"
    echo "   sudo security add-trusted-cert -d -r trustRoot -p ssl -k /Library/Keychains/System.keychain \"$CERTS_DIR/root-ca.crt\""
    echo ""
    echo "⚠️  CRITICAL: After running the command above, quit Chrome completely (Cmd + Q)"
    echo "   and reopen to test."
  fi
fi
echo "=========================================================================="

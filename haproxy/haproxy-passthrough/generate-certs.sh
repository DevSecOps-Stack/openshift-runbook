#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$DIR/certs"
mkdir -p "$CERTS_DIR"
cd "$CERTS_DIR"

echo "🔐 [1/4] Generating BrainyBots Enterprise Root CA (The Trust Anchor)..."
openssl req -x509 -new -nodes -newkey rsa:4096 \
  -keyout root-ca.key \
  -out root-ca.crt \
  -days 3650 \
  -subj "/C=AU/O=BrainyBots Enterprise/OU=Security/CN=BrainyBots Enterprise Root CA"

echo "🔐 [2/4] Generating Backend Pod Private Key and CSR..."
openssl req -new -nodes -newkey rsa:2048 \
  -keyout server.key \
  -out server.csr \
  -subj "/C=AU/O=BrainyBots Enterprise/CN=*.testapp-passthrough.apps.okd-sno.brainybots.cloud"

echo "🔐 [3/4] Creating Scoped SAN Configuration & Signing Server Certificate..."
cat << 'EOF' > san.cnf
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.testapp-passthrough.apps.okd-sno.brainybots.cloud
EOF

openssl x509 -req -in server.csr \
  -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
  -out server.crt -days 365 -extfile san.cnf

# Create the full certificate chain (Server Cert + Root CA)
cat server.crt root-ca.crt > fullchain.crt

echo "🔐 [4/4] Injecting base64 certificates into 01-tls-secret.yaml..."
FULLCHAIN_B64=$(cat fullchain.crt | base64 | tr -d '\n')
KEY_B64=$(cat server.key | base64 | tr -d '\n')

cat << EOF > "$DIR/01-tls-secret.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: passthrough-tls-secret
  namespace: demo-testapp-passthrough
type: kubernetes.io/tls
data:
  tls.crt: "$FULLCHAIN_B64"
  tls.key: "$KEY_B64"
EOF

echo ""
echo "=========================================================================="
echo "✅ Backend Pod TLS Secret Populated into 01-tls-secret.yaml!"
echo "🔒 To trust this certificate in macOS (eliminating browser warnings):"
echo "   sudo security delete-certificate -c \"BrainyBots Enterprise Root CA\" /Library/Keychains/System.keychain 2>/dev/null || true"
echo "   sudo security add-trusted-cert -d -r trustRoot -p ssl -k /Library/Keychains/System.keychain \"$CERTS_DIR/root-ca.crt\""
echo ""
echo "⚠️  CRITICAL: After running the command above, quit Chrome completely (Cmd + Q)"
echo "   and reopen to test: https://passthrough-app.testapp-passthrough.apps.okd-sno.brainybots.cloud"
echo "=========================================================================="

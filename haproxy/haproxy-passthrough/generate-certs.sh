#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$DIR/certs"
mkdir -p "$CERTS_DIR"
cd "$CERTS_DIR"

echo "🔐 [1/3] Generating BrainyBots Enterprise Root CA (if not already present)..."
if [ ! -f "root-ca.key" ] || [ ! -f "root-ca.crt" ]; then
  openssl req -x509 -new -nodes -newkey rsa:4096 \
    -keyout root-ca.key \
    -out root-ca.crt \
    -days 3650 \
    -subj "/C=AU/O=BrainyBots Enterprise/OU=Security/CN=BrainyBots Enterprise Root CA"
else
  echo "   ...found existing root-ca.crt"
fi

echo "🔐 [2/3] Generating Backend Pod Private Key and CSR..."
openssl req -new -nodes -newkey rsa:2048 \
  -keyout passthrough.key \
  -out passthrough.csr \
  -subj "/C=AU/O=BrainyBots Enterprise/CN=passthrough-app.testapp-passthrough.apps.okd-sno.brainybots.cloud"

cat << 'EOF' > san.cnf
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = passthrough-app.testapp-passthrough.apps.okd-sno.brainybots.cloud
DNS.2 = *.testapp-passthrough.apps.okd-sno.brainybots.cloud
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
echo "🔒 Notice: This secret goes to demo-testapp-passthrough (mounted in the Pod)."
echo "   HAProxy router NEVER sees or holds this certificate!"
echo "=========================================================================="

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

echo "🔐 [2/3] Generating Public Ingress Key and CSR for testapp-reencrypt..."
openssl req -new -nodes -newkey rsa:2048 \
  -keyout server.key \
  -out server.csr \
  -subj "/C=AU/O=BrainyBots Enterprise/CN=*.apps.okd-sno.brainybots.cloud"

cat << 'EOF' > san.cnf
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.apps.okd-sno.brainybots.cloud
DNS.2 = apps.okd-sno.brainybots.cloud
DNS.3 = *.testapp-reencrypt.apps.okd-sno.brainybots.cloud
DNS.4 = reencrypt-app.testapp-reencrypt.apps.okd-sno.brainybots.cloud
EOF

echo "🔐 [3/3] Signing Ingress Certificate with Enterprise Root CA..."
openssl x509 -req -in server.csr \
  -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
  -out server.crt -days 365 -extfile san.cnf

# Bundle full chain
cat server.crt root-ca.crt > fullchain.crt

# Populate 01-tls-secret.yaml
FULLCHAIN_B64=$(cat fullchain.crt | base64 | tr -d '\n')
KEY_B64=$(cat server.key | base64 | tr -d '\n')

cat << EOF > "$DIR/01-tls-secret.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: reencrypt-wildcard-tls
  namespace: openshift-ingress
type: kubernetes.io/tls
data:
  tls.crt: "$FULLCHAIN_B64"
  tls.key: "$KEY_B64"
EOF

echo ""
echo "=========================================================================="
echo "✅ Re-encrypt Ingress TLS Secret Populated into 01-tls-secret.yaml!"
echo "=========================================================================="
echo "ℹ️  Remember the Re-encrypt Architecture:"
echo "   1. Leg 1 (Client ➔ Router): Encrypted using reencrypt-wildcard-tls (mounted in router)."
echo "   2. Leg 2 (Router ➔ Pod): Encrypted using internal cert auto-issued by OpenShift Service CA!"
echo "=========================================================================="

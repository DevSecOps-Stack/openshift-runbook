#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🧹 [1/4] Deleting OpenShift cluster resources..."
oc delete project edge-app --ignore-not-found=true
oc delete ingresscontroller edge-app-ingress -n openshift-ingress-operator --ignore-not-found=true
oc delete secret custom-wildcard-tls -n openshift-ingress --ignore-not-found=true

echo "🧹 [2/4] Cleaning local cert artifacts..."
rm -rf "$DIR/certs"
rm -f /tmp/active-root-ca.crt /tmp/cert*.crt /tmp/keychain-ca.crt

echo "🧹 [3/4] Resetting 01-tls-secret.yaml..."
cat << 'EOF' > "$DIR/01-tls-secret.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: custom-wildcard-tls
  namespace: openshift-ingress
type: kubernetes.io/tls
data:
  # Injected automatically by generate-certs.sh
  tls.crt: ""
  tls.key: ""
EOF

echo "🧹 [4/4] Removing BrainyBots Root CA from macOS System Keychain..."
if sudo security delete-certificate -c "BrainyBots Enterprise Root CA" /Library/Keychains/System.keychain 2>/dev/null; then
  echo "   ✅ Removed BrainyBots Enterprise Root CA from System Keychain."
else
  echo "   ℹ️ No BrainyBots certificate found in System Keychain."
fi

echo ""
echo "=========================================================================="
echo "✅ Complete Cleanup Finished! Environment is a clean slate."
echo "=========================================================================="
echo "💡 Tip: Run 'killall \"Google Chrome\"' to reset your browser SSL cache."
echo "=========================================================================="

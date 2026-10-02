#!/usr/bin/env bash
set -e

echo "=========================================================================="
echo "🧹 TEARING DOWN ALL CUSTOM DEMOS & LOAD BALANCERS ON OKD"
echo "=========================================================================="

echo ""
echo "1️⃣  Deleting Custom IngressControllers..."
oc delete ingresscontroller testapp-reencrypt-ingress testapp-passthrough-ingress edge-app-ingress ib-pnv1-ingress -n openshift-ingress-operator --ignore-not-found

echo ""
echo "2️⃣  Deleting Demo Namespaces (Pods, Deployments, Services, Routes)..."
oc delete ns demo-testapp-reencrypt demo-testapp-passthrough edge-app pnv1-team tls-demo --ignore-not-found

echo ""
echo "3️⃣  Deleting Custom TLS Secrets in openshift-ingress..."
oc delete secret custom-wildcard-tls pnv1-custom-tls-bundle reencrypt-wildcard-tls -n openshift-ingress --ignore-not-found

echo ""
echo "⏳ Waiting for GCP Cloud Controller to clean up Forwarding Rules and Load Balancers..."
sleep 15

echo ""
echo "=========================================================================="
echo "✅ Active IngressControllers (Only 'default' should remain):"
oc get ingresscontroller -n openshift-ingress-operator
echo ""
echo "✅ Remaining GCP Forwarding Rules (Only default cluster LBs should remain):"
gcloud compute forwarding-rules list --project=project-d1e9a331-9d48-41a4-b3c
echo "=========================================================================="

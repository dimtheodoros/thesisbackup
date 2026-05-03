#!/bin/bash
set -euo pipefail

# --- Configuration ---
NAMESPACE="online-boutique"
WEST_KUBECONFIG="./.generated/kubeconfig-eu-west.yaml"
NORTH_KUBECONFIG="./.generated/kubeconfig-eu-north.yaml"
KARMADA_DATA="./.generated/karmada"
KARMADA_KUBECONFIG="${KARMADA_DATA}/karmada-apiserver.config"

echo "🧹 Starting Layer 1 Cleanup (Karmada)..."

# 1. Delete Istio CRDs directly from both clusters
echo "🗑️ Removing Istio locality and ingress manifests..."
KUBECONFIG="$WEST_KUBECONFIG"  kubectl delete -f manifests/online-boutique-locality.yaml --ignore-not-found
KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete -f manifests/online-boutique-locality.yaml --ignore-not-found
KUBECONFIG="$WEST_KUBECONFIG"  kubectl delete -f manifests/online-boutique-ingress-gateway.yaml --ignore-not-found
KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete -f manifests/online-boutique-ingress-gateway.yaml --ignore-not-found
KUBECONFIG="$WEST_KUBECONFIG"  kubectl delete -f manifests/online-boutique-ingress-virtualservice.yaml --ignore-not-found
KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete -f manifests/online-boutique-ingress-virtualservice.yaml --ignore-not-found

# 2. Port-forward karmada-apiserver so we can talk to the Karmada control plane
echo "🔌 Opening port-forward to Karmada API server..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl port-forward svc/karmada-apiserver \
  -n karmada-system 5443:5443 &>/dev/null &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 3

# Patch kubeconfig to use localhost:5443
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl config set-cluster karmada-apiserver \
  --server="https://127.0.0.1:5443" \
  --insecure-skip-tls-verify=true
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl config unset \
  clusters.karmada-apiserver.certificate-authority-data

# 3. Delete PropagationPolicies (triggers Karmada to remove workloads from member clusters)
echo "🗑️ Removing PropagationPolicies..."
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete -f manifests/karmada/propagation-policy.yaml --ignore-not-found

# 4. Delete boutique resources from the Karmada API server
echo "🗑️ Removing boutique resources from Karmada..."
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete -f .generated/boutique-resources.yaml --ignore-not-found || true
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete -f .generated/loadgenerator.yaml --ignore-not-found || true

# 5. Unjoin member clusters
echo "🔓 Unjoining eu-west..."
karmadactl unjoin eu-west \
  --kubeconfig="$KARMADA_KUBECONFIG" \
  --cluster-kubeconfig="$WEST_KUBECONFIG" || true

echo "🔓 Unjoining eu-north..."
karmadactl unjoin eu-north \
  --kubeconfig="$KARMADA_KUBECONFIG" \
  --cluster-kubeconfig="$NORTH_KUBECONFIG" || true

# 6. Stop port-forward
kill $PF_PID 2>/dev/null || true
trap - EXIT

# 7. Remove Karmada control plane from west cluster via Helm
echo "🗑️ Removing Karmada control plane from west cluster..."
helm uninstall karmada \
  --kubeconfig "$WEST_KUBECONFIG" \
  --namespace karmada-system || true

echo "✨ Layer 1 Karmada cleaned up successfully!"

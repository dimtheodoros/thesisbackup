#!/bin/bash
set -euo pipefail

# --- Configuration ---
NAMESPACE="online-boutique"
WEST_KUBECONFIG="./.generated/kubeconfig-eu-west.yaml"
NORTH_KUBECONFIG="./.generated/kubeconfig-eu-north.yaml"
KARMADA_DATA="./.generated/karmada"
KARMADA_KUBECONFIG="${KARMADA_DATA}/karmada-apiserver.config"
CHART_PATH="./OnlineBoutique app/helm-chart"

mkdir -p "$KARMADA_DATA"

echo "🚀 Starting Layer 1 Deployment (Karmada)..."

# 1. Check prerequisites
if ! command -v karmadactl &>/dev/null; then
  echo "❌ karmadactl not found. Install: brew install karmadactl"
  exit 1
fi

# 2. Install Karmada via Helm.
#    karmadactl init uses NodePort to reach the newly-created karmada-apiserver from
#    the local machine, which fails on EKS private nodes. The Helm chart uses an
#    in-cluster bootstrap Job instead, so no external node connectivity is required.
echo "📦 Adding Karmada Helm repo..."
helm repo add karmada-charts https://raw.githubusercontent.com/karmada-io/karmada/master/charts 2>/dev/null || true
helm repo update karmada-charts

echo "📦 Installing Karmada on west cluster (this takes ~3 min)..."
helm upgrade --install karmada karmada-charts/karmada \
  --kubeconfig "$WEST_KUBECONFIG" \
  --namespace karmada-system \
  --create-namespace \
  --wait \
  --timeout 10m

# 3. Extract karmada-apiserver kubeconfig from the secret the Helm chart creates
echo "🔑 Extracting Karmada kubeconfig from secret..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl get secret karmada-kubeconfig \
  -n karmada-system \
  -o jsonpath='{.data.kubeconfig}' | base64 -d > "$KARMADA_KUBECONFIG"

# 4. Port-forward the karmada-apiserver so the ClusterIP-based kubeconfig is reachable.
#    The cert is issued for the ClusterIP, so we also disable TLS verification.
echo "🔌 Opening port-forward to Karmada API server..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl port-forward svc/karmada-apiserver \
  -n karmada-system 5443:5443 &>/dev/null &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 3

KUBECONFIG="$KARMADA_KUBECONFIG" kubectl config set-cluster karmada-apiserver \
  --server="https://127.0.0.1:5443" \
  --insecure-skip-tls-verify=true
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl config unset \
  clusters.karmada-apiserver.certificate-authority-data

# 5. Join both EKS clusters as Karmada member clusters
echo "🔗 Joining eu-west..."
karmadactl join eu-west \
  --kubeconfig="$KARMADA_KUBECONFIG" \
  --cluster-kubeconfig="$WEST_KUBECONFIG"

echo "🔗 Joining eu-north..."
karmadactl join eu-north \
  --kubeconfig="$KARMADA_KUBECONFIG" \
  --cluster-kubeconfig="$NORTH_KUBECONFIG"

# 6. Create online-boutique namespace in the Karmada API server
echo "📁 Creating namespace in Karmada..."
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl create ns "$NAMESPACE" --dry-run=client -o yaml \
  | KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply -f -
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl label ns "$NAMESPACE" istio-injection=enabled --overwrite

# 7. Render boutique chart (no HPA, no loadgenerator) and apply to Karmada API server
echo "📦 Rendering boutique chart..."
helm template online-boutique "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --set loadGenerator.create=false \
  > .generated/boutique-resources.yaml

# Render loadgenerator separately — PropagationPolicy targets eu-west only
helm template online-boutique "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --set loadGenerator.create=true \
  --show-only templates/loadgenerator.yaml \
  > .generated/loadgenerator.yaml

echo "📤 Applying boutique resources to Karmada API server..."
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply -f .generated/boutique-resources.yaml
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply -f .generated/loadgenerator.yaml

# 8. Apply PropagationPolicies (boutique → both clusters, loadgenerator → west only)
echo "📋 Applying PropagationPolicies..."
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply -f manifests/karmada/propagation-policy.yaml

# 9. Apply Istio CRDs directly to each cluster (not managed by Karmada)
echo "🛠️ Applying Istio locality failover rules and ingress manifests..."
KUBECONFIG="$WEST_KUBECONFIG"  kubectl apply -f manifests/online-boutique-locality.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/online-boutique-locality.yaml
KUBECONFIG="$WEST_KUBECONFIG"  kubectl apply -f manifests/online-boutique-ingress-gateway.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/online-boutique-ingress-gateway.yaml
KUBECONFIG="$WEST_KUBECONFIG"  kubectl apply -f manifests/online-boutique-ingress-virtualservice.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/online-boutique-ingress-virtualservice.yaml

# 10. Stop port-forward; expose karmada-apiserver as LoadBalancer for external access
kill $PF_PID 2>/dev/null || true
trap - EXIT

echo "🌐 Exposing Karmada API server as LoadBalancer..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl patch svc karmada-apiserver \
  -n karmada-system \
  -p '{"spec":{"type":"LoadBalancer"}}'

echo "⏳ Waiting for Karmada API server LoadBalancer hostname..."
while true; do
  KARMADA_HOST=$(KUBECONFIG="$WEST_KUBECONFIG" kubectl get svc karmada-apiserver \
    -n karmada-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  [ -n "$KARMADA_HOST" ] && break
  sleep 5
done

KUBECONFIG="$KARMADA_KUBECONFIG" kubectl config set-cluster karmada-apiserver \
  --server="https://${KARMADA_HOST}:5443" \
  --insecure-skip-tls-verify=true

echo "✨ Layer 1 Karmada Deployed Successfully!"
echo "------------------------------------------------"
echo "Karmada kubeconfig: $KARMADA_KUBECONFIG"
echo "Karmada API server: https://${KARMADA_HOST}:5443"
echo ""
echo "Check cluster status:"
echo "  kubectl get clusters --kubeconfig $KARMADA_KUBECONFIG"
echo "Check propagation:"
echo "  kubectl get propagationpolicy -n $NAMESPACE --kubeconfig $KARMADA_KUBECONFIG"

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
  --cluster-kubeconfig="$WEST_KUBECONFIG" || true

echo "🔗 Joining eu-north..."
karmadactl join eu-north \
  --kubeconfig="$KARMADA_KUBECONFIG" \
  --cluster-kubeconfig="$NORTH_KUBECONFIG" || true

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

# Render loadgenerator — targets internal frontend service so boutique-propagation
# pushes it to both clusters; each pod resolves "frontend" via local cluster DNS
helm template online-boutique "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --set loadGenerator.create=true \
  --set loadGenerator.frontendAddr=frontend:80 \
  --show-only templates/loadgenerator.yaml \
  > .generated/loadgenerator.yaml

echo "📤 Applying boutique resources to Karmada API server..."
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply -f .generated/boutique-resources.yaml
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply -f .generated/loadgenerator.yaml

# 8. Apply PropagationPolicies (boutique → both clusters)
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

# 10. Enable karmada-metrics-adapter so FederatedHPA can collect cross-cluster CPU metrics
echo "📊 Enabling karmada-metrics-adapter..."
# The addon expects a secret named karmada-metrics-adapter-config with key "karmada.config".
# karmadactl init creates this automatically, but we use Helm, so we create it manually.
# The server URL must be the in-cluster service DNS so the adapter can reach the Karmada API.
ADAPTER_KC="/tmp/karmada-adapter-bootstrap.config"
KUBECONFIG="$WEST_KUBECONFIG" kubectl get secret karmada-kubeconfig \
  -n karmada-system -o jsonpath='{.data.kubeconfig}' | base64 -d > "$ADAPTER_KC"
KUBECONFIG="$ADAPTER_KC" kubectl config set-cluster karmada-apiserver \
  --server="https://karmada-apiserver.karmada-system.svc.cluster.local:5443" \
  --insecure-skip-tls-verify=true
KUBECONFIG="$ADAPTER_KC" kubectl config unset \
  clusters.karmada-apiserver.certificate-authority-data 2>/dev/null || true

KUBECONFIG="$WEST_KUBECONFIG" kubectl create secret generic karmada-metrics-adapter-config \
  -n karmada-system --from-file=karmada.config="$ADAPTER_KC" \
  --dry-run=client -o yaml | KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f -
rm -f "$ADAPTER_KC"

karmadactl addons enable karmada-metrics-adapter \
  --kubeconfig="$WEST_KUBECONFIG" \
  --karmada-kubeconfig="$KARMADA_KUBECONFIG" \
  --namespace karmada-system || true

# Fix 1: karmada-cert has key "server-ca.crt" but the adapter expects "/etc/karmada/pki/ca.crt".
# Patch the Deployment to remap the secret key to the expected filename.
echo "🔧 Patching karmada-metrics-adapter cert volume..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl patch deployment karmada-metrics-adapter \
  -n karmada-system --type=json -p='[{
    "op": "replace",
    "path": "/spec/template/spec/volumes/1",
    "value": {
      "name": "k8s-certs",
      "secret": {
        "defaultMode": 420,
        "secretName": "karmada-cert",
        "items": [
          {"key": "server-ca.crt",         "path": "ca.crt"},
          {"key": "karmada.crt",           "path": "karmada.crt"},
          {"key": "karmada.key",           "path": "karmada.key"},
          {"key": "front-proxy-ca.crt",    "path": "front-proxy-ca.crt"},
          {"key": "front-proxy-client.crt","path": "front-proxy-client.crt"},
          {"key": "front-proxy-client.key","path": "front-proxy-client.key"}
        ]
      }
    }
  }]'

# Fix 2: karmadactl addons times out before registering APIServices in the Karmada API
# server, so we apply them explicitly. insecureSkipTLSVerify is required because the
# adapter cert is signed by the Karmada CA which the aggregation layer doesn't trust.
# We also need an ExternalName service in Karmada's own namespace store so the
# aggregation layer can resolve karmada-metrics-adapter.karmada-system to the actual
# pod running on the host cluster.
echo "🔧 Registering metrics APIServices and ExternalName resolver in Karmada..."
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply -f - <<'METRICS_EOF'
---
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1beta1.metrics.k8s.io
spec:
  service:
    name: karmada-metrics-adapter
    namespace: karmada-system
    port: 443
  group: metrics.k8s.io
  version: v1beta1
  insecureSkipTLSVerify: true
  groupPriorityMinimum: 100
  versionPriority: 100
---
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1beta1.custom.metrics.k8s.io
spec:
  service:
    name: karmada-metrics-adapter
    namespace: karmada-system
    port: 443
  group: custom.metrics.k8s.io
  version: v1beta1
  insecureSkipTLSVerify: true
  groupPriorityMinimum: 100
  versionPriority: 100
---
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1beta2.custom.metrics.k8s.io
spec:
  service:
    name: karmada-metrics-adapter
    namespace: karmada-system
    port: 443
  group: custom.metrics.k8s.io
  version: v1beta2
  insecureSkipTLSVerify: true
  groupPriorityMinimum: 100
  versionPriority: 100
---
apiVersion: v1
kind: Service
metadata:
  name: karmada-metrics-adapter
  namespace: karmada-system
spec:
  type: ExternalName
  externalName: karmada-metrics-adapter.karmada-system.svc.cluster.local
  ports:
  - name: https
    port: 443
    targetPort: 443
    protocol: TCP
METRICS_EOF

echo "⏳ Waiting for karmada-metrics-adapter pod to be ready..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl rollout status deployment/karmada-metrics-adapter \
  -n karmada-system --timeout=120s

# 11. Stop port-forward; expose karmada-apiserver as LoadBalancer for external access
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

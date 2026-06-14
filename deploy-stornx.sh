#!/bin/bash
# deploy-stornx.sh — Layer 3: StornX OptiBalancer integration
#
# Deploys one StornX instance per cluster in the 'stornx' namespace.
# Each instance optimises Istio DestinationRule traffic weights for the
# online-boutique namespace using real-time Prometheus + Istio metrics.
#
# Prerequisites: deploy-karmada.sh and deploy-monitoring.sh must have run first.
# OptiScaler is disabled (SCALER_RESPECT_HPA=true); FederatedHPA continues to
# handle cross-cluster pod scaling.
set -euo pipefail

WEST_KUBECONFIG="./.generated/kubeconfig-eu-west.yaml"
NORTH_KUBECONFIG="./.generated/kubeconfig-eu-north.yaml"
NAMESPACE="online-boutique"
STORNX_NS="stornx"

# Path to the local StornX Helm chart (cloned alongside this repo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORNX_CHART="${SCRIPT_DIR}/../StornX/.kubernetes/helm"

if [ ! -d "$STORNX_CHART" ]; then
  echo "ERROR: StornX chart not found at $STORNX_CHART"
  echo "       Clone https://github.com/AposLaz/StornX next to this repo first."
  exit 1
fi

echo "StornX integration — deploying OptiBalancer to both clusters"
echo "Chart: $STORNX_CHART"
echo ""

# ---------------------------------------------------------------------------
# 1. Helm repos (kube-netlag is a sub-chart; this ensures its chart can be
#    resolved if a 'helm dependency update' is ever needed)
# ---------------------------------------------------------------------------
echo "Adding Helm repos..."
helm repo add stornx https://aposlaz.github.io/StornX 2>/dev/null || true
helm repo add kube-netlag https://aposlaz.github.io/kube-netlag 2>/dev/null || true
helm repo update

# ---------------------------------------------------------------------------
# 2. Create stornx namespace on both clusters
# ---------------------------------------------------------------------------
echo "Creating '$STORNX_NS' namespace on both clusters..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl create namespace "$STORNX_NS" --dry-run=client -o yaml \
  | KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f -
KUBECONFIG="$NORTH_KUBECONFIG" kubectl create namespace "$STORNX_NS" --dry-run=client -o yaml \
  | KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f -

# ---------------------------------------------------------------------------
# 3. Remove existing static locality DestinationRules from both clusters.
#    StornX will create its own DRs (named without the -locality suffix) that
#    include both distribute weights AND outlierDetection for ejection-based
#    cross-cluster failover via the east-west gateway.
# ---------------------------------------------------------------------------
LOCALITY_DRS=(
  adservice-locality
  cartservice-locality
  checkoutservice-locality
  currencyservice-locality
  emailservice-locality
  frontend-locality
  paymentservice-locality
  productcatalogservice-locality
  recommendationservice-locality
  shippingservice-locality
  redis-cart-locality
)

echo "Removing static locality DestinationRules from eu-west..."
for dr in "${LOCALITY_DRS[@]}"; do
  KUBECONFIG="$WEST_KUBECONFIG" kubectl delete destinationrule "$dr" -n "$NAMESPACE" --ignore-not-found=true
done

echo "Removing static locality DestinationRules from eu-north..."
for dr in "${LOCALITY_DRS[@]}"; do
  KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete destinationrule "$dr" -n "$NAMESPACE" --ignore-not-found=true
done

# ---------------------------------------------------------------------------
# 4. Install StornX on eu-west
# ---------------------------------------------------------------------------
echo ""
echo "Installing StornX on eu-west (Belgium)..."
helm upgrade --install stornx "$STORNX_CHART" \
  --kubeconfig "$WEST_KUBECONFIG" \
  --namespace "$STORNX_NS" \
  --values "manifests/stornx/values-west.yaml" \
  --wait --timeout 5m

# ---------------------------------------------------------------------------
# 5. Install StornX on eu-north
# ---------------------------------------------------------------------------
echo "Installing StornX on eu-north (Finland)..."
helm upgrade --install stornx "$STORNX_CHART" \
  --kubeconfig "$NORTH_KUBECONFIG" \
  --namespace "$STORNX_NS" \
  --values "manifests/stornx/values-north.yaml" \
  --wait --timeout 5m

# ---------------------------------------------------------------------------
# 6. Apply PodMonitors so kube-prometheus-stack scrapes:
#    a) kube-netlag  → node_avg_latency_ms (required by StornX's latency gating)
#    b) Istio sidecars with job="kubernetes-pods" + node label (required by
#       OptiBalancer's upstream/downstream graph queries)
# ---------------------------------------------------------------------------
echo "Applying PodMonitors to both clusters..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f manifests/stornx/kube-netlag-podmonitor.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/stornx/kube-netlag-podmonitor.yaml
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f manifests/stornx/istio-podmonitor.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/stornx/istio-podmonitor.yaml

# ---------------------------------------------------------------------------
# 7. Bootstrap OptiBalancer on both clusters.
#
#    OptiBalancer only runs via the normal threshold path when services are
#    heavily loaded; with single-replica boutique services at idle it never
#    fires that way. Instead we seed deploys.json (the same file OptiScaler
#    writes after a scaling event) so the first cron cycle after the metrics
#    are ready will run OptiBalancer for the full service graph and create
#    the initial DestinationRules.
#
#    Steps:
#      a) Wait for kube-netlag to produce node_avg_latency_ms (StornX exits
#         early without it).
#      b) Wait for the Istio PodMonitor to be scraped (job=kubernetes-pods
#         must exist before OptiBalancer graph queries will return data).
#      c) Write bootstrap entries; OptiBalancer picks them up on the next
#         minute boundary.
# ---------------------------------------------------------------------------
echo ""
echo "Waiting for Prometheus metrics to be ready (kube-netlag + Istio graph)..."

_wait_metrics() {
  local kubeconfig="$1"
  local cluster="$2"
  local stornx_pod
  stornx_pod=$(KUBECONFIG="$kubeconfig" kubectl get pods -n "$STORNX_NS" \
    -l app.kubernetes.io/name=stornx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  local prom="http://prometheus-operated.${NAMESPACE}.svc.cluster.local:9090"
  local attempts=0

  until KUBECONFIG="$kubeconfig" kubectl exec -n "$STORNX_NS" "$stornx_pod" -- \
    node -e "
const http=require('http');
function q(query,cb){
  http.get('${prom}/api/v1/query?query='+encodeURIComponent(query),res=>{
    let d='';res.on('data',c=>d+=c);res.on('end',()=>{
      const r=JSON.parse(d);
      cb(r.data&&r.data.result&&r.data.result.length>0);
    });
  }).on('error',()=>cb(false));
}
q('node_avg_latency_ms',ok1=>{
  q('istio_requests_total{job=\"kubernetes-pods\",node!=\"\"}',ok2=>{
    process.exit(ok1&&ok2?0:1);
  });
});
" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 24 ]; then
      echo "  WARNING: metrics not ready on $cluster after 2 min — bootstrap skipped."
      return 1
    fi
    echo "  [$cluster] waiting for metrics... (${attempts}/24)"
    sleep 5
  done
  echo "  [$cluster] metrics ready."
  return 0
}

_bootstrap() {
  local kubeconfig="$1"
  local cluster="$2"
  local stornx_pod
  stornx_pod=$(KUBECONFIG="$kubeconfig" kubectl get pods -n "$STORNX_NS" \
    -l app.kubernetes.io/name=stornx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  KUBECONFIG="$kubeconfig" kubectl exec -n "$STORNX_NS" "$stornx_pod" -- \
    node -e "
const fs=require('fs');
fs.mkdirSync('/opt/data/deploys',{recursive:true});
const data=[
  {deployment:'frontend',namespace:'${NAMESPACE}'},
  {deployment:'checkoutservice',namespace:'${NAMESPACE}'},
  {deployment:'cartservice',namespace:'${NAMESPACE}'}
];
fs.writeFileSync('/opt/data/deploys/deploys.json',JSON.stringify(data));
console.log('Bootstrap written for ${cluster}');
" 2>&1
}

# Run both clusters in parallel (background)
_wait_and_bootstrap() {
  local kubeconfig="$1"
  local cluster="$2"
  if _wait_metrics "$kubeconfig" "$cluster"; then
    _bootstrap "$kubeconfig" "$cluster"
  fi
}

_wait_and_bootstrap "$WEST_KUBECONFIG" "eu-west" &
_wait_and_bootstrap "$NORTH_KUBECONFIG" "eu-north" &
wait

echo ""
echo "Bootstrap complete. OptiBalancer will create DestinationRules on the next"
echo "cron cycle (within 60 seconds) for both clusters."

# ---------------------------------------------------------------------------
# 8. Status summary
# ---------------------------------------------------------------------------
echo ""
echo "StornX deployed successfully!"
echo "--------------------------------------------------"
echo "StornX pods (eu-west):"
KUBECONFIG="$WEST_KUBECONFIG" kubectl get pods -n "$STORNX_NS" -l app.kubernetes.io/name=stornx 2>/dev/null || true
echo ""
echo "StornX pods (eu-north):"
KUBECONFIG="$NORTH_KUBECONFIG" kubectl get pods -n "$STORNX_NS" -l app.kubernetes.io/name=stornx 2>/dev/null || true
echo ""
echo "kube-netlag DaemonSet (eu-west, one pod per node):"
KUBECONFIG="$WEST_KUBECONFIG" kubectl get ds -n "$STORNX_NS" 2>/dev/null || true
echo ""
echo "Verify DestinationRules (wait ~60s after bootstrap):"
echo "  kubectl get destinationrule -n $NAMESPACE --kubeconfig $WEST_KUBECONFIG"
echo "  kubectl get destinationrule -n $NAMESPACE --kubeconfig $NORTH_KUBECONFIG"

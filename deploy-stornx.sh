#!/bin/bash
# deploy-stornx.sh — Layer 3: StornX OptiBalancer + OptiScaler integration
#
# Deploys one StornX instance per cluster in the 'stornx' namespace.
# Both OptiBalancer (Istio DR weight optimisation) and OptiScaler (per-cluster
# pod placement and replica scaling) are active. FederatedHPA is NOT used.
#
# Also deploys the cross-cluster-fallback controller on each cluster, which
# increments the OTHER cluster's replica count when the local cluster is
# resource-exhausted and OptiScaler cannot schedule a new replica locally.
#
# Prerequisites: deploy-karmada.sh and deploy-monitoring.sh must have run first.
# Do NOT apply experiments/manifests/scenario4-north-stress-fhpa.yaml.
set -euo pipefail

WEST_KUBECONFIG="./.generated/kubeconfig-eu-west.yaml"
NORTH_KUBECONFIG="./.generated/kubeconfig-eu-north.yaml"
KARMADA_KUBECONFIG="./.generated/karmada/karmada-apiserver.config"
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

echo "StornX integration — deploying OptiBalancer + OptiScaler to both clusters"
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
# 7. Apply the bootstrap CronJob to both clusters.
#    Runs every minute and repopulates /opt/data/deploys/deploys.json so
#    OptiBalancer fires on every cron cycle after StornX clears the file.
# ---------------------------------------------------------------------------
echo "Applying bootstrap CronJob to both clusters..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f manifests/stornx/bootstrap-cronjob.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/stornx/bootstrap-cronjob.yaml

# ---------------------------------------------------------------------------
# 8. Detach Deployments from Karmada so OptiScaler has uncontested control
#    over spec.replicas on each member cluster.
#
#    In Karmada's Duplicated mode the propagation controller reconciles
#    member-cluster Deployments back to the Karmada-layer replica count
#    within seconds of any change — which would immediately undo every
#    OptiScaler scale-up/down. Removing the Deployment resource selector
#    stops this reconciliation. Services and ServiceAccounts remain managed
#    by Karmada and are unaffected.
#
#    Because Karmada garbage-collects resources that are no longer selected
#    by any PropagationPolicy, we save the current Deployment specs first,
#    patch the policy, wait for GC to complete, then re-apply the Deployments
#    directly to each cluster so they survive independently.
# ---------------------------------------------------------------------------
echo ""
echo "Detaching Deployments from Karmada propagation (OptiScaler takes over)..."

# Save Deployment specs from Karmada before the policy patch triggers GC.
# Captured as JSON so resourceVersion/uid/managedFields/status can be stripped
# with jq — Karmada's hub resourceVersion never matches a member cluster's own
# resourceVersion sequence, so re-applying it as-is causes a 409 Conflict on
# every Deployment.
DEPS_JSON=$(KUBECONFIG="$KARMADA_KUBECONFIG" kubectl get deployments \
  -n "$NAMESPACE" -o json 2>/dev/null)

# Remove the apps/v1 Deployment entry from resourceSelectors. The "test" op
# guards against re-running this script: if Deployment is no longer at index 0
# (already detached by a prior run), the whole patch is rejected atomically and
# nothing else in resourceSelectors is touched.
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl patch propagationpolicy boutique-propagation \
  -n "$NAMESPACE" --type=json \
  -p='[{"op":"test","path":"/spec/resourceSelectors/0/kind","value":"Deployment"},{"op":"remove","path":"/spec/resourceSelectors/0"}]' \
  2>/dev/null || echo "  Deployment selector already absent from PropagationPolicy — skipping (already detached)."

# Narrowing the selector does NOT retroactively release resources already
# bound under the old policy — Karmada keeps reconciling existing
# ResourceBindings regardless of the current selector, which silently
# reverts any direct kubectl edit on the member cluster within seconds.
# Deleting the Deployment-kind bindings is what actually releases ownership
# (cascades to delete the Works and the propagated member-cluster objects,
# since PreserveResourcesOnDeletion isn't set) — the re-apply below then
# recreates them as independent, self-managed objects.
echo "  Deleting stale Deployment ResourceBindings so Karmada releases ownership..."
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl get resourcebindings -n "$NAMESPACE" -o json \
  | jq -r '.items[] | select(.spec.resource.kind=="Deployment") | .metadata.name' \
  | while read -r rb; do
      [ -n "$rb" ] && KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete resourcebinding "$rb" -n "$NAMESPACE" --ignore-not-found
    done

echo "  Waiting 20s for the binding deletion to propagate to both clusters..."
sleep 20

CLEAN_DEPS=$(echo "$DEPS_JSON" | jq '{
  apiVersion: "v1",
  kind: "List",
  items: [.items[] | del(
    .metadata.resourceVersion,
    .metadata.uid,
    .metadata.creationTimestamp,
    .metadata.generation,
    .metadata.managedFields,
    .metadata.selfLink,
    .status
  )]
}')

# Re-apply Deployments directly to each cluster; they are now self-managed
echo "$CLEAN_DEPS" | KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f - -n "$NAMESPACE"
echo "$CLEAN_DEPS" | KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f - -n "$NAMESPACE"
echo "  Deployments applied directly to both clusters."

# ---------------------------------------------------------------------------
# 9. Create cross-cluster kubeconfig Secrets.
#    Each cluster's fallback controller needs credentials for the OTHER cluster
#    so it can patch Deployments there when local capacity is exhausted.
#
#    The admin kubeconfigs in .generated/ use AWS IAM exec-auth (`aws eks
#    get-token`), which requires the AWS CLI plus IAM credentials mapped into
#    that specific cluster's aws-auth — neither is available inside the
#    fallback controller pod, and the other cluster's node IAM role is not
#    mapped there. Instead, apply a scoped ServiceAccount + Role on each
#    cluster and build a static, token-based kubeconfig for the other
#    cluster's controller to mount — no exec plugin required.
# ---------------------------------------------------------------------------
echo ""
echo "Setting up cross-cluster remote-access ServiceAccounts..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f manifests/stornx/cross-cluster-remote-access.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/stornx/cross-cluster-remote-access.yaml

_build_remote_kubeconfig() {
  local kubeconfig="$1"
  local cluster_name="$2"

  local server ca token
  server=$(KUBECONFIG="$kubeconfig" kubectl config view --minify --flatten \
    -o jsonpath='{.clusters[0].cluster.server}')
  ca=$(KUBECONFIG="$kubeconfig" kubectl config view --minify --flatten \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

  local attempts=0
  until token=$(KUBECONFIG="$kubeconfig" kubectl get secret cross-cluster-remote-token \
      -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null) && [ -n "$token" ]; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 20 ]; then
      echo "  ERROR: token Secret for $cluster_name never populated." >&2
      return 1
    fi
    sleep 2
  done
  token=$(echo "$token" | base64 -d)

  cat <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${cluster_name}
  cluster:
    server: ${server}
    certificate-authority-data: ${ca}
contexts:
- name: ${cluster_name}
  context:
    cluster: ${cluster_name}
    user: cross-cluster-remote
    namespace: ${NAMESPACE}
current-context: ${cluster_name}
users:
- name: cross-cluster-remote
  user:
    token: ${token}
EOF
}

echo "Building static kubeconfig for eu-north's remote-access ServiceAccount..."
_build_remote_kubeconfig "$NORTH_KUBECONFIG" "eu-north" > /tmp/cross-cluster-kubeconfig-north.yaml

echo "Building static kubeconfig for eu-west's remote-access ServiceAccount..."
_build_remote_kubeconfig "$WEST_KUBECONFIG" "eu-west" > /tmp/cross-cluster-kubeconfig-west.yaml

echo "Creating cross-cluster kubeconfig Secrets..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl create secret generic cross-cluster-kubeconfig \
  -n "$STORNX_NS" --from-file=kubeconfig=/tmp/cross-cluster-kubeconfig-north.yaml \
  --dry-run=client -o yaml \
  | KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f -

KUBECONFIG="$NORTH_KUBECONFIG" kubectl create secret generic cross-cluster-kubeconfig \
  -n "$STORNX_NS" --from-file=kubeconfig=/tmp/cross-cluster-kubeconfig-west.yaml \
  --dry-run=client -o yaml \
  | KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f -

rm -f /tmp/cross-cluster-kubeconfig-north.yaml /tmp/cross-cluster-kubeconfig-west.yaml

echo "  eu-west gets a token-based kubeconfig for eu-north, and vice versa."

# ---------------------------------------------------------------------------
# 10. Deploy the cross-cluster fallback controller on both clusters.
#     Polls every 60s; when a deployment is CPU-saturated and no local node
#     has sufficient free CPU, increments replicas on the other cluster.
#     5-minute per-deployment cooldown prevents rapid churn.
# ---------------------------------------------------------------------------
echo ""
echo "Deploying cross-cluster fallback controller to both clusters..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f manifests/stornx/cross-cluster-fallback.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/stornx/cross-cluster-fallback.yaml

# ---------------------------------------------------------------------------
# 11. Bootstrap OptiBalancer on both clusters.
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
# 12. Status summary
# ---------------------------------------------------------------------------
echo ""
echo "StornX (OptiBalancer + OptiScaler) deployed successfully!"
echo "--------------------------------------------------"
echo "StornX pods (eu-west):"
KUBECONFIG="$WEST_KUBECONFIG" kubectl get pods -n "$STORNX_NS" -l app.kubernetes.io/name=stornx 2>/dev/null || true
echo ""
echo "StornX pods (eu-north):"
KUBECONFIG="$NORTH_KUBECONFIG" kubectl get pods -n "$STORNX_NS" -l app.kubernetes.io/name=stornx 2>/dev/null || true
echo ""
echo "Cross-cluster fallback controller (eu-west):"
KUBECONFIG="$WEST_KUBECONFIG" kubectl get pods -n "$STORNX_NS" -l app=cross-cluster-fallback 2>/dev/null || true
echo ""
echo "Cross-cluster fallback controller (eu-north):"
KUBECONFIG="$NORTH_KUBECONFIG" kubectl get pods -n "$STORNX_NS" -l app=cross-cluster-fallback 2>/dev/null || true
echo ""
echo "kube-netlag DaemonSet (eu-west, one pod per node):"
KUBECONFIG="$WEST_KUBECONFIG" kubectl get ds -n "$STORNX_NS" 2>/dev/null || true
echo ""
echo "PropagationPolicy (Deployments should NOT appear in resourceSelectors):"
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl get propagationpolicy boutique-propagation \
  -n "$NAMESPACE" -o jsonpath='{.spec.resourceSelectors}' 2>/dev/null || true
echo ""
echo ""
echo "Verify DestinationRules (wait ~60s after bootstrap):"
echo "  kubectl get destinationrule -n $NAMESPACE --kubeconfig $WEST_KUBECONFIG"
echo "  kubectl get destinationrule -n $NAMESPACE --kubeconfig $NORTH_KUBECONFIG"
echo ""
echo "NOTE: Do NOT apply experiments/manifests/scenario4-north-stress-fhpa.yaml"
echo "      OptiScaler manages scaling; FederatedHPA is not active in this setup."

#!/bin/bash
# Scenario 5 — Asymmetric Organic Load via Karmada OverridePolicy + Locust LoadTestShape
#
# West stays at 100 users (controlled by set_load_users). North follows a custom
# Locust LoadTestShape (experiments/manifests/locustfile-north-shape.py) delivered
# via a ConfigMap + OverridePolicy that mounts it into the north loadgenerator pod
# at boot. The shape drives genuine application-level CPU pressure without requiring
# any mid-experiment pod restarts.
#
# North LoadTestShape stage timeline (cumulative seconds from pod start):
#   0–120s   baseline       —   10 users  (west=10)
#   120–300s ramp_symmetric —  100 users  (west=100)
#   300–600s north_overload —  600 users  (west=100, 6:1 ratio)
#   600–900s north_peak     — 1000 users  (west=100, 10:1 ratio; expect 5xx + Istio failover)
#   900–1140s recovery      —  100 users  (west=100, north cooling down)
#   1140–1260s ramp_down    —   10 users  (west=10)
#
# Usage: bash experiments/scenario-5-north-organic-overload.sh
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
. experiments/lib/common.sh

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_DIR="experiments/results/scenario-5-north-organic-${TIMESTAMP}"
FHPA_APPLIED=false
SHAPE_APPLIED=false
LOAD_CHANGED=false

cleanup() {
  if [ "$SHAPE_APPLIED" = "true" ]; then
    remove_north_locust_shape
  fi
  if [ "$LOAD_CHANGED" = "true" ]; then
    log_info "Restoring loadgenerator to 10 users..."
    set_west_load_users 10 2>/dev/null || true
  fi
  if [ "$FHPA_APPLIED" = "true" ]; then
    log_info "Removing FederatedHPAs..."
    KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete federatedhpa \
      -n "$NAMESPACE" --all 2>/dev/null || true
  fi
  stop_west_prometheus_portforward
  stop_karmada_portforward
  log_info "Scenario 5 done. Results: $RESULT_DIR/"
}
trap cleanup EXIT INT TERM

check_prerequisites
start_karmada_portforward

if karmada_owns_deployments; then
  log_phase "SETUP" "Applying FederatedHPAs (minReplicas=1, CPU target: 40%)"
  KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply \
    -f experiments/manifests/scenario4-north-stress-fhpa.yaml
  FHPA_APPLIED=true
  log_info "Waiting 30s for FederatedHPA propagation..."
  sleep 30
else
  log_phase "SETUP" "Skipping FederatedHPAs — OptiScaler manages replicas directly (Deployments detached from Karmada)"
fi

resolve_north_prometheus
start_west_prometheus_portforward
init_metric_csvs "$RESULT_DIR"

log_phase "SETUP" "Deploying north Locust LoadTestShape (shape clock starts at T=0)"
apply_north_locust_shape; SHAPE_APPLIED=true
# North loadgenerator is now Running with the custom shape. The shape's internal
# clock started at pod boot. The script's phase durations below are sized to match
# the shape's stage boundaries (120s / 180s / 300s / 300s / 240s / 120s).

log_phase "BASELINE" "2 min — north shape T=0–120s (10 users), west at 10 users"
collect_metrics_loop_multi "$RESULT_DIR" "baseline" 120

set_west_load_users 100; LOAD_CHANGED=true
# North shape transitions to 100 users at T=120s independently.
log_phase "RAMP_SYMMETRIC" "3 min — north shape T≈120–300s (100 users), west=100"
collect_metrics_loop_multi "$RESULT_DIR" "ramp_symmetric" 180

# North shape transitions to 600 users at T=300s automatically.
log_phase "NORTH_OVERLOAD" "5 min — north shape T≈300–600s (600 users, 6:1), west=100"
collect_metrics_loop_multi "$RESULT_DIR" "north_overload" 300

# North shape transitions to 1000 users at T=600s automatically.
log_phase "NORTH_PEAK" "5 min — north shape T≈600–900s (1000 users, 10:1), expect 5xx + Istio failover"
collect_metrics_loop_multi "$RESULT_DIR" "north_peak" 300

# North shape transitions to 100 users at T=900s automatically.
log_phase "RECOVERY" "4 min — north shape T≈900–1140s (100 users), Istio reinstates north endpoints"
collect_metrics_loop_multi "$RESULT_DIR" "recovery" 240

set_west_load_users 10; LOAD_CHANGED=false
# North shape transitions to 10 users at T=1140s automatically.
log_phase "RAMP_DOWN" "2 min — north shape T≈1140–1260s (10 users), replicas scale back down"
collect_metrics_loop_multi "$RESULT_DIR" "ramp_down" 120

log_info "Removing north shape OverridePolicy and ConfigMap..."
remove_north_locust_shape; SHAPE_APPLIED=false

if [ "$FHPA_APPLIED" = "true" ]; then
  log_info "Removing FederatedHPAs..."
  KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete federatedhpa \
    -n "$NAMESPACE" --all --ignore-not-found
  FHPA_APPLIED=false
fi

echo ""
log_info "Scenario 5 complete. Results saved to: $RESULT_DIR/"

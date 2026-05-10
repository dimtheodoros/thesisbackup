#!/bin/bash
# Scenario 3 — Load Ramp with FederatedHPA
# Deploys a FederatedHPA targeting frontend CPU at 50% utilisation.
# Ramps load via the loadgenerator USERS env var: 10 → 50 → 150 → 300 → 600 → 10.
# FederatedHPA automatically scales frontend replicas in response.
# In Duplicated mode each cluster gets the full scaled replica count.
#
# Usage: bash experiments/scenario-3-load-ramp-fhpa.sh
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
. experiments/lib/common.sh

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_FILE="experiments/results/scenario-3-load-ramp-${TIMESTAMP}.csv"
FHPA_APPLIED=false
LOAD_CHANGED=false

cleanup() {
  if [ "$LOAD_CHANGED" = "true" ]; then
    log_info "Restoring loadgenerator to 10 users..."
    KUBECONFIG="$KARMADA_KUBECONFIG" kubectl set env deployment/loadgenerator \
      -n "$NAMESPACE" USERS="10" SPAWN_RATE="1" 2>/dev/null || true
  fi
  if [ "$FHPA_APPLIED" = "true" ]; then
    log_info "Removing FederatedHPA..."
    KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete federatedhpa frontend-fhpa \
      -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  fi
  stop_west_prometheus_portforward
  stop_karmada_portforward
  log_info "Scenario 3 done. Results: $RESULT_FILE"
}
trap cleanup EXIT INT TERM

check_prerequisites
start_karmada_portforward

log_phase "DEPLOY_FHPA" "Applying FederatedHPA for frontend (CPU target: 50%)"
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply \
  -f experiments/manifests/scenario3-federated-hpa.yaml
FHPA_APPLIED=true
log_info "Waiting 20s for FederatedHPA to register..."
sleep 20

resolve_north_prometheus
start_west_prometheus_portforward
write_csv_header "$RESULT_FILE"

log_phase "BASELINE" "2 min at default load (10 users) — FederatedHPA at min replicas"
collect_metrics_loop "$RESULT_FILE" "baseline_10u" 120

set_load_users 50; LOAD_CHANGED=true
log_phase "RAMP_50U" "3 min at 50 users"
collect_metrics_loop "$RESULT_FILE" "ramp_50u" 180

set_load_users 150
log_phase "RAMP_150U" "3 min at 150 users"
collect_metrics_loop "$RESULT_FILE" "ramp_150u" 180

set_load_users 300
log_phase "RAMP_300U" "4 min at 300 users"
collect_metrics_loop "$RESULT_FILE" "ramp_300u" 240

set_load_users 600
log_phase "RAMP_600U" "5 min at 600 users — peak load, watch FederatedHPA scale up"
collect_metrics_loop "$RESULT_FILE" "ramp_600u" 300

set_load_users 10; LOAD_CHANGED=false
log_phase "RAMP_DOWN" "4 min scale-down — watch FederatedHPA reduce replicas"
collect_metrics_loop "$RESULT_FILE" "ramp_down" 240

echo ""
log_info "Scenario 3 complete. Results saved to: $RESULT_FILE"

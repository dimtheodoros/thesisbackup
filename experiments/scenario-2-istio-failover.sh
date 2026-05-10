#!/bin/bash
# Scenario 2 — Istio Locality Failover
# Simulates a full eu-north outage by setting all Deployments to 0 replicas via
# a Karmada OverridePolicy. Istio outlier detection redirects traffic to eu-west.
# Records: pre-failover baseline, outage period, and recovery.
#
# Usage: bash experiments/scenario-2-istio-failover.sh
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
. experiments/lib/common.sh

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_FILE="experiments/results/scenario-2-failover-${TIMESTAMP}.csv"
NORTH_ZERO_APPLIED=false

cleanup() {
  if [ "$NORTH_ZERO_APPLIED" = "true" ]; then
    log_info "Removing north-zero-replicas OverridePolicy..."
    KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete overridepolicy north-zero-replicas \
      -n "$NAMESPACE" --ignore-not-found || true
  fi
  stop_west_prometheus_portforward
  stop_karmada_portforward
  log_info "Scenario 2 done. Results: $RESULT_FILE"
}
trap cleanup EXIT INT TERM

check_prerequisites
start_karmada_portforward
resolve_north_prometheus
start_west_prometheus_portforward
write_csv_header "$RESULT_FILE"

log_phase "PRE_FAILOVER" "2 min baseline — both clusters healthy"
collect_metrics_loop "$RESULT_FILE" "pre_failover" 120

log_phase "APPLY_FAILOVER" "Setting eu-north replicas to 0 via Karmada OverridePolicy"
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply \
  -f experiments/manifests/scenario2-north-zero-replicas.yaml
NORTH_ZERO_APPLIED=true
log_info "Waiting 45s for Karmada to propagate and pods to terminate on eu-north..."
sleep 45

log_phase "FAILOVER" "5 min during simulated eu-north outage — watch west absorb all traffic"
collect_metrics_loop "$RESULT_FILE" "failover" 300

log_phase "RESTORE" "Removing OverridePolicy — eu-north pods will restart"
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete overridepolicy north-zero-replicas \
  -n "$NAMESPACE" --ignore-not-found
NORTH_ZERO_APPLIED=false
log_info "Waiting 60s for eu-north pods to come back up..."
sleep 60
wait_for_deployments_ready 240

log_phase "RECOVERY" "5 min recovery — traffic rebalancing back to both clusters"
collect_metrics_loop "$RESULT_FILE" "recovery" 300

echo ""
log_info "Scenario 2 complete. Results saved to: $RESULT_FILE"

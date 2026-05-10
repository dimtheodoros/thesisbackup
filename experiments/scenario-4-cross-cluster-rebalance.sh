#!/bin/bash
# Scenario 4 — Cross-Cluster Rebalancing
# Switches to Divided + AvailableReplicas placement mode and deploys FederatedHPA.
# A CPU stress pod saturates eu-west, reducing its available capacity.
# Karmada scheduler shifts replica weight toward eu-north; FederatedHPA scales total count up.
# Demonstrates intelligent cross-cluster workload redistribution under resource pressure.
#
# Usage: bash experiments/scenario-4-cross-cluster-rebalance.sh
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
. experiments/lib/common.sh

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_FILE="experiments/results/scenario-4-rebalance-${TIMESTAMP}.csv"
DIVIDED_APPLIED=false
FHPA_APPLIED=false
STRESS_APPLIED=false

cleanup() {
  if [ "$STRESS_APPLIED" = "true" ]; then
    log_info "Removing CPU stress pod from eu-west..."
    KUBECONFIG="$WEST_KUBECONFIG" kubectl delete pod cpu-stress \
      -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  fi
  if [ "$FHPA_APPLIED" = "true" ]; then
    log_info "Removing FederatedHPAs..."
    KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete federatedhpa \
      -n "$NAMESPACE" --all 2>/dev/null || true
  fi
  if [ "$DIVIDED_APPLIED" = "true" ]; then
    log_info "Restoring Duplicated PropagationPolicy..."
    KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply \
      -f manifests/karmada/propagation-policy.yaml 2>/dev/null || true
  fi
  stop_west_prometheus_portforward
  stop_karmada_portforward
  log_info "Scenario 4 done. Results: $RESULT_FILE"
}
trap cleanup EXIT INT TERM

check_prerequisites
start_karmada_portforward

log_phase "SETUP" "Switching to Divided placement mode and deploying FederatedHPA"
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply \
  -f experiments/manifests/scenario34-divided-propagation-policy.yaml
DIVIDED_APPLIED=true
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply \
  -f experiments/manifests/scenario3-federated-hpa.yaml
FHPA_APPLIED=true
log_info "Waiting 60s for policy propagation and replica redistribution..."
sleep 60

resolve_north_prometheus
start_west_prometheus_portforward
write_csv_header "$RESULT_FILE"

log_phase "BASELINE_DIVIDED" "2 min baseline in Divided mode — equal capacity, balanced replicas"
collect_metrics_loop "$RESULT_FILE" "baseline_divided" 120

log_phase "APPLY_STRESS" "Deploying CPU stress pod on eu-west (2 cores)"
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply \
  -f experiments/manifests/scenario4-stress-pod.yaml
STRESS_APPLIED=true
log_info "Waiting 30s for stress to register in metrics server..."
sleep 30

log_phase "STRESS_ACTIVE" "5 min — stress saturates eu-west, Karmada shifts weight to eu-north"
collect_metrics_loop "$RESULT_FILE" "stress_active" 300

log_phase "REBALANCE_OBSERVE" "5 min — observe replica distribution and latency stabilisation"
collect_metrics_loop "$RESULT_FILE" "rebalance_observe" 300

log_phase "REMOVE_STRESS" "Removing CPU stress pod"
KUBECONFIG="$WEST_KUBECONFIG" kubectl delete pod cpu-stress \
  -n "$NAMESPACE" --ignore-not-found
STRESS_APPLIED=false
log_info "Waiting 30s for capacity to recover..."
sleep 30

log_phase "RECOVERY" "5 min recovery — replica weight rebalances back to equal distribution"
collect_metrics_loop "$RESULT_FILE" "recovery" 300

log_phase "RESTORE_POLICY" "Restoring original Duplicated PropagationPolicy"
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply \
  -f manifests/karmada/propagation-policy.yaml
DIVIDED_APPLIED=false
log_info "Removing FederatedHPAs..."
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete federatedhpa \
  -n "$NAMESPACE" --all --ignore-not-found
FHPA_APPLIED=false

echo ""
log_info "Scenario 4 complete. Results saved to: $RESULT_FILE"

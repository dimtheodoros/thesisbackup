#!/bin/bash
# Scenario 4 — Cross-Cluster Rebalancing
# Switches to Divided + AvailableReplicas placement mode with minReplicas=2 FederatedHPAs,
# ensuring both clusters always have at least one replica of each service.
# Ramps load to 150 users to trigger FederatedHPA scaling, then applies a CPU stress pod
# on eu-west. Karmada shifts new replicas toward eu-north (more available capacity).
# Removing the stress pod causes replicas to rebalance back toward equal distribution.
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
LOAD_CHANGED=false

cleanup() {
  if [ "$LOAD_CHANGED" = "true" ]; then
    log_info "Restoring loadgenerator to 10 users..."
    KUBECONFIG="$KARMADA_KUBECONFIG" kubectl set env deployment/loadgenerator \
      -n "$NAMESPACE" USERS="10" SPAWN_RATE="1" 2>/dev/null || true
  fi
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

log_phase "SETUP" "Divided placement mode + FederatedHPAs (minReplicas=2, CPU target: 60%)"
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply \
  -f experiments/manifests/scenario34-divided-propagation-policy.yaml
DIVIDED_APPLIED=true
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply \
  -f experiments/manifests/scenario4-federated-hpa.yaml
FHPA_APPLIED=true
log_info "Waiting 60s for policy propagation — both clusters should reach 1 replica each..."
sleep 60

resolve_north_prometheus
start_west_prometheus_portforward
write_csv_header "$RESULT_FILE"

log_phase "BASELINE_DIVIDED" "2 min at 10 users — Divided mode, 1 replica per cluster per service"
collect_metrics_loop "$RESULT_FILE" "baseline_divided" 120

set_load_users 150; LOAD_CHANGED=true
log_phase "RAMP_LOAD" "3 min at 150 users — FederatedHPA scales up, equal distribution across clusters"
collect_metrics_loop "$RESULT_FILE" "ramp_load" 180

log_phase "APPLY_STRESS" "Deploying CPU stress pod on eu-west (400m request / 2 CPU limit)"
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply \
  -f experiments/manifests/scenario4-stress-pod.yaml
STRESS_APPLIED=true
log_info "Waiting 30s for stress to register in metrics server..."
sleep 30

log_phase "STRESS_ACTIVE" "5 min — west capacity reduced, Karmada shifts new replicas to north"
collect_metrics_loop "$RESULT_FILE" "stress_active" 300

log_phase "REBALANCE_OBSERVE" "3 min — observe stabilised replica asymmetry between clusters"
collect_metrics_loop "$RESULT_FILE" "rebalance_observe" 180

log_phase "REMOVE_STRESS" "Removing CPU stress pod"
KUBECONFIG="$WEST_KUBECONFIG" kubectl delete pod cpu-stress \
  -n "$NAMESPACE" --ignore-not-found
STRESS_APPLIED=false
log_info "Waiting 30s for capacity to recover..."
sleep 30

log_phase "RECOVERY" "4 min — west capacity restored, replicas rebalance toward equal distribution"
collect_metrics_loop "$RESULT_FILE" "recovery" 240

set_load_users 10; LOAD_CHANGED=false
log_phase "RAMP_DOWN" "2 min — FederatedHPA scales back toward minReplicas=2"
collect_metrics_loop "$RESULT_FILE" "ramp_down" 120

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

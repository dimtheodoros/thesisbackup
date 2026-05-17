#!/bin/bash
# Scenario 4 — North Cluster Extreme Stress
# Both clusters run a loadgenerator (Duplicated mode, each targeting local frontend:80).
# FederatedHPAs are applied at ramp_load. The north cluster is then progressively
# stressed: CPU throttling first (Istio outlier detection, gradual traffic shift),
# then RAM exhaustion added (OOM kills, hard Istio failover), then both at peak.
# West cluster hosts Karmada and monitoring and is never stressed.
# Recovery observes Istio reinstating north endpoints and FederatedHPA scaling down.
#
# Usage: bash experiments/scenario-4-north-stress-failover.sh
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
. experiments/lib/common.sh

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_FILE="experiments/results/scenario-4-north-stress-${TIMESTAMP}.csv"
FHPA_APPLIED=false
CPU_STRESS_APPLIED=false
RAM_STRESS_APPLIED=false
LOAD_CHANGED=false

cleanup() {
  if [ "$LOAD_CHANGED" = "true" ]; then
    log_info "Restoring loadgenerator to 10 users..."
    KUBECONFIG="$KARMADA_KUBECONFIG" kubectl set env deployment/loadgenerator \
      -n "$NAMESPACE" USERS="10" SPAWN_RATE="1" 2>/dev/null || true
  fi
  if [ "$RAM_STRESS_APPLIED" = "true" ]; then
    log_info "Removing RAM stress pod from north..."
    KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete pod north-ram-stress \
      -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  fi
  if [ "$CPU_STRESS_APPLIED" = "true" ]; then
    log_info "Removing CPU stress pod from north..."
    KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete pod north-cpu-stress \
      -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  fi
  if [ "$FHPA_APPLIED" = "true" ]; then
    log_info "Removing FederatedHPAs..."
    KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete federatedhpa \
      -n "$NAMESPACE" --all 2>/dev/null || true
  fi
  stop_west_prometheus_portforward
  stop_karmada_portforward
  log_info "Scenario 4 done. Results: $RESULT_FILE"
}
trap cleanup EXIT INT TERM

check_prerequisites
start_karmada_portforward

log_phase "SETUP" "Applying FederatedHPAs (minReplicas=1, CPU target: 40%)"
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl apply \
  -f experiments/manifests/scenario4-north-stress-fhpa.yaml
FHPA_APPLIED=true
log_info "Waiting 30s for FederatedHPA propagation..."
sleep 30

resolve_north_prometheus
start_west_prometheus_portforward
write_csv_header "$RESULT_FILE"

log_phase "BASELINE" "2 min at 10 users — clean floor, both clusters idle"
collect_metrics_loop "$RESULT_FILE" "baseline" 120

set_load_users 200; LOAD_CHANGED=true
log_phase "RAMP_LOAD" "3 min at 200 users per cluster — FederatedHPA scaling under healthy load"
collect_metrics_loop "$RESULT_FILE" "ramp_load" 180

log_phase "CPU_STRESS" "Deploying CPU stress pod on north (400m request / 2 CPU limit)"
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply \
  -f experiments/manifests/scenario4-north-cpu-stress-pod.yaml
CPU_STRESS_APPLIED=true
log_info "Waiting 30s for CPU stress to register in metrics server..."
sleep 30

log_phase "CPU_STRESS_ACTIVE" "5 min — north pods throttled, Istio outlier detection triggers, traffic shifts to west"
collect_metrics_loop "$RESULT_FILE" "cpu_stress" 300

log_phase "RAM_STRESS" "Adding RAM stress pod on north (3G consumed, CPU stress continues)"
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply \
  -f experiments/manifests/scenario4-north-ram-stress-pod.yaml
RAM_STRESS_APPLIED=true
log_info "Waiting 30s for memory pressure to build..."
sleep 30

log_phase "RAM_STRESS_ACTIVE" "5 min — OOM kills on north, hard Istio failover, west absorbs full load"
collect_metrics_loop "$RESULT_FILE" "ram_stress" 300

log_phase "EXTREME" "3 min — both stressors at peak, maximum cluster asymmetry"
collect_metrics_loop "$RESULT_FILE" "extreme" 180

log_phase "REMOVE_STRESS" "Removing both stress pods from north"
KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete pod north-ram-stress \
  -n "$NAMESPACE" --ignore-not-found
RAM_STRESS_APPLIED=false
KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete pod north-cpu-stress \
  -n "$NAMESPACE" --ignore-not-found
CPU_STRESS_APPLIED=false
log_info "Waiting 30s for north nodes to recover..."
sleep 30

log_phase "RECOVERY" "4 min — north pods restart, Istio reinstates endpoints, traffic rebalances"
collect_metrics_loop "$RESULT_FILE" "recovery" 240

set_load_users 10; LOAD_CHANGED=false
log_phase "RAMP_DOWN" "2 min — FederatedHPA scales back to minReplicas"
collect_metrics_loop "$RESULT_FILE" "ramp_down" 120

log_info "Removing FederatedHPAs..."
KUBECONFIG="$KARMADA_KUBECONFIG" kubectl delete federatedhpa \
  -n "$NAMESPACE" --all --ignore-not-found
FHPA_APPLIED=false

echo ""
log_info "Scenario 4 complete. Results saved to: $RESULT_FILE"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_DIR="${SCRIPT_DIR}/results/scenario-6-north-zone-failure-${TIMESTAMP}"
TARGET_ZONE="eu-north-1a"
DRAINED_NODE=""
ZONE_DRAINED=false
LOAD_CHANGED=false

cleanup() {
  [ "$ZONE_DRAINED" = "true" ] && uncordon_north_node "$DRAINED_NODE" 2>/dev/null || true
  [ "$LOAD_CHANGED" = "true" ] && \
    set_load_users 10 2>/dev/null || true
  stop_west_prometheus_portforward
  stop_karmada_portforward
  log_info "Results: ${RESULT_DIR}/"
}
trap cleanup EXIT INT TERM

check_prerequisites
start_karmada_portforward

# Resolve target node by zone label before any load changes
DRAINED_NODE=$(KUBECONFIG="$NORTH_KUBECONFIG" kubectl get nodes \
  -l "topology.kubernetes.io/zone=${TARGET_ZONE}" \
  -o jsonpath='{.items[0].metadata.name}')
[ -z "$DRAINED_NODE" ] && die "No node found in zone ${TARGET_ZONE} on north cluster"
log_info "Target node for zone drop: ${DRAINED_NODE} (${TARGET_ZONE})"

resolve_north_prometheus
start_west_prometheus_portforward
init_metric_csvs "$RESULT_DIR"

# --- Phase 1: Baseline ---
log_phase "baseline" "200 users symmetric, all zones healthy"
set_load_users 200
LOAD_CHANGED=true
collect_metrics_loop_multi "$RESULT_DIR" "baseline" 120

# --- Zone Drop ---
cordon_and_drain_north_node "$DRAINED_NODE"
ZONE_DRAINED=true

# --- Phase 2: Zone Degraded ---
log_phase "zone_degraded" "${TARGET_ZONE} drained — pod rescheduling + Istio failover"
collect_metrics_loop_multi "$RESULT_DIR" "zone_degraded" 300

# --- Zone Recovery ---
uncordon_north_node "$DRAINED_NODE"
ZONE_DRAINED=false

# --- Phase 3: Recovery ---
log_phase "zone_recovery" "${TARGET_ZONE} restored — pods redistributing"
collect_metrics_loop_multi "$RESULT_DIR" "zone_recovery" 240

# --- Ramp Down ---
set_load_users 10
LOAD_CHANGED=false
log_phase "ramp_down" "load reduction"
collect_metrics_loop_multi "$RESULT_DIR" "ramp_down" 60

echo "Results: ${RESULT_DIR}/"

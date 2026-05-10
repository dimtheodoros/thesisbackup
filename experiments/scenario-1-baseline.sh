#!/bin/bash
# Scenario 1 — Baseline
# Collects 7 minutes of steady-state metrics (2 min warmup + 5 min baseline).
# No cluster changes. Run first to establish the control measurement.
#
# Usage: bash experiments/scenario-1-baseline.sh
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
. experiments/lib/common.sh

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_FILE="experiments/results/scenario-1-baseline-${TIMESTAMP}.csv"

cleanup() {
  stop_west_prometheus_portforward
  stop_karmada_portforward
  log_info "Scenario 1 done. Results: $RESULT_FILE"
}
trap cleanup EXIT INT TERM

check_prerequisites
start_karmada_portforward
resolve_north_prometheus
start_west_prometheus_portforward
write_csv_header "$RESULT_FILE"

log_phase "WARMUP" "2 min warmup — allowing Istio metrics to stabilize before recording"
collect_metrics_loop "$RESULT_FILE" "warmup" 120

log_phase "BASELINE" "5 min baseline — steady-state metrics under default load"
collect_metrics_loop "$RESULT_FILE" "baseline" 300

echo ""
log_info "Scenario 1 complete. Results saved to: $RESULT_FILE"

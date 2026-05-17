#!/bin/bash
# Shared configuration and utilities for experiment scripts.
# Source this file from each scenario: . experiments/lib/common.sh

NAMESPACE="online-boutique"
WEST_KUBECONFIG="./.generated/kubeconfig-eu-west.yaml"
NORTH_KUBECONFIG="./.generated/kubeconfig-eu-north.yaml"
KARMADA_KUBECONFIG="./.generated/karmada/karmada-apiserver.config"
WEST_PROM_URL="http://localhost:9091"
NORTH_PROM_URL=""
KARMADA_PF_PID=""
WEST_PROM_PF_PID=""
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-15}"

# ── Logging ──────────────────────────────────────────────────────────────────

log_phase() {
  local name="$1" desc="$2"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  [$(date -u +%H:%M:%SZ)] PHASE: ${name}"
  echo "  ${desc}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

log_info() {
  echo "  [$(date -u +%H:%M:%SZ)] $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# ── Prerequisites ─────────────────────────────────────────────────────────────

check_prerequisites() {
  local missing=0
  for cmd in kubectl jq curl karmadactl; do
    command -v "$cmd" &>/dev/null || { log_info "ERROR: '$cmd' not found"; missing=1; }
  done
  [ -f "$WEST_KUBECONFIG" ]    || { log_info "ERROR: $WEST_KUBECONFIG not found"; missing=1; }
  [ -f "$NORTH_KUBECONFIG" ]   || { log_info "ERROR: $NORTH_KUBECONFIG not found"; missing=1; }
  [ -f "$KARMADA_KUBECONFIG" ] || { log_info "ERROR: $KARMADA_KUBECONFIG not found"; missing=1; }
  if [ "$missing" -eq 1 ]; then die "Prerequisites not met. Run deploy-karmada.sh and deploy-monitoring.sh first."; fi
}

# ── Port management ───────────────────────────────────────────────────────────

kill_port() {
  lsof -ti tcp:"$1" 2>/dev/null | xargs kill -9 2>/dev/null || true
}

start_karmada_portforward() {
  kill_port 5443
  KUBECONFIG="$WEST_KUBECONFIG" kubectl port-forward svc/karmada-apiserver \
    -n karmada-system 5443:5443 &>/dev/null &
  KARMADA_PF_PID=$!
  sleep 3
  KUBECONFIG="$KARMADA_KUBECONFIG" kubectl config set-cluster karmada-apiserver \
    --server="https://127.0.0.1:5443" --insecure-skip-tls-verify=true 2>/dev/null
  KUBECONFIG="$KARMADA_KUBECONFIG" kubectl config unset \
    clusters.karmada-apiserver.certificate-authority-data 2>/dev/null || true
  log_info "Karmada port-forward ready (PID $KARMADA_PF_PID)"
}

stop_karmada_portforward() {
  [ -n "$KARMADA_PF_PID" ] && kill "$KARMADA_PF_PID" 2>/dev/null || true
  KARMADA_PF_PID=""
}

start_west_prometheus_portforward() {
  kill_port 9091
  KUBECONFIG="$WEST_KUBECONFIG" kubectl port-forward svc/prometheus-operated \
    -n "$NAMESPACE" 9091:9090 &>/dev/null &
  WEST_PROM_PF_PID=$!
  sleep 3
  log_info "West Prometheus port-forward ready on :9091 (PID $WEST_PROM_PF_PID)"
}

stop_west_prometheus_portforward() {
  [ -n "$WEST_PROM_PF_PID" ] && kill "$WEST_PROM_PF_PID" 2>/dev/null || true
  WEST_PROM_PF_PID=""
}

resolve_north_prometheus() {
  log_info "Resolving North Prometheus LoadBalancer hostname..."
  local hostname=""
  for i in $(seq 1 12); do
    hostname=$(KUBECONFIG="$NORTH_KUBECONFIG" kubectl get svc prometheus-public \
      -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [ -n "$hostname" ] && { NORTH_PROM_URL="http://${hostname}:9090"; log_info "North Prometheus: $NORTH_PROM_URL"; return 0; }
    sleep 5
  done
  die "Could not resolve North Prometheus LoadBalancer after 60s"
}

# ── Prometheus querying ───────────────────────────────────────────────────────

prom_query() {
  local url="$1" query="$2"
  local encoded
  encoded=$(printf '%s' "$query" | jq -Rr @uri)
  curl -sf --max-time 10 "${url}/api/v1/query?query=${encoded}" \
    | jq -r '.data.result[0].value[1] // "NaN"' 2>/dev/null || echo "NaN"
}

# ── CSV metrics collection ────────────────────────────────────────────────────

write_csv_header() {
  printf 'timestamp,phase,west_rps,north_rps,west_p99_ms,north_p99_ms,west_error_rate,north_error_rate,west_frontend_replicas,north_frontend_replicas,west_adservice_replicas,north_adservice_replicas,west_currencyservice_replicas,north_currencyservice_replicas,west_productcatalogservice_replicas,north_productcatalogservice_replicas,loadgenerator_users,west_mem_pct,north_mem_pct,west_restarts,north_restarts\n' \
    > "$1"
}

collect_metrics_row() {
  local filepath="$1" phase="$2"
  local ts west_rps north_rps west_p99 north_p99 west_err north_err \
        west_rep north_rep west_ad_rep north_ad_rep \
        west_cur_rep north_cur_rep west_pcs_rep north_pcs_rep lg_users \
        west_mem_pct north_mem_pct west_restarts north_restarts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  west_rps=$(prom_query "$WEST_PROM_URL" \
    'sum(rate(istio_requests_total{reporter="destination",destination_service_namespace="online-boutique",source_workload!~"prometheus.*"}[1m]))')
  north_rps=$(prom_query "$NORTH_PROM_URL" \
    'sum(rate(istio_requests_total{reporter="destination",destination_service_namespace="online-boutique",source_workload!~"prometheus.*"}[1m]))')

  west_p99=$(prom_query "$WEST_PROM_URL" \
    'histogram_quantile(0.99,sum by(le)(rate(istio_request_duration_milliseconds_bucket{reporter="destination",destination_service_namespace="online-boutique",source_workload!~"prometheus.*"}[1m])))')
  north_p99=$(prom_query "$NORTH_PROM_URL" \
    'histogram_quantile(0.99,sum by(le)(rate(istio_request_duration_milliseconds_bucket{reporter="destination",destination_service_namespace="online-boutique",source_workload!~"prometheus.*"}[1m])))')

  west_err=$(prom_query "$WEST_PROM_URL" \
    'sum(rate(istio_requests_total{reporter="destination",destination_service_namespace="online-boutique",response_code=~"5.."}[1m])) / sum(rate(istio_requests_total{reporter="destination",destination_service_namespace="online-boutique"}[1m]))')
  north_err=$(prom_query "$NORTH_PROM_URL" \
    'sum(rate(istio_requests_total{reporter="destination",destination_service_namespace="online-boutique",response_code=~"5.."}[1m])) / sum(rate(istio_requests_total{reporter="destination",destination_service_namespace="online-boutique"}[1m]))')

  west_rep=$(prom_query "$WEST_PROM_URL" \
    'kube_deployment_status_replicas_available{namespace="online-boutique",deployment="frontend"}')
  north_rep=$(prom_query "$NORTH_PROM_URL" \
    'kube_deployment_status_replicas_available{namespace="online-boutique",deployment="frontend"}')

  west_ad_rep=$(prom_query "$WEST_PROM_URL" \
    'kube_deployment_status_replicas_available{namespace="online-boutique",deployment="adservice"}')
  north_ad_rep=$(prom_query "$NORTH_PROM_URL" \
    'kube_deployment_status_replicas_available{namespace="online-boutique",deployment="adservice"}')

  west_cur_rep=$(prom_query "$WEST_PROM_URL" \
    'kube_deployment_status_replicas_available{namespace="online-boutique",deployment="currencyservice"}')
  north_cur_rep=$(prom_query "$NORTH_PROM_URL" \
    'kube_deployment_status_replicas_available{namespace="online-boutique",deployment="currencyservice"}')

  west_pcs_rep=$(prom_query "$WEST_PROM_URL" \
    'kube_deployment_status_replicas_available{namespace="online-boutique",deployment="productcatalogservice"}')
  north_pcs_rep=$(prom_query "$NORTH_PROM_URL" \
    'kube_deployment_status_replicas_available{namespace="online-boutique",deployment="productcatalogservice"}')

  west_mem_pct=$(prom_query "$WEST_PROM_URL" \
    'avg(container_memory_working_set_bytes{namespace="online-boutique",container!="",container!="POD",container!="istio-proxy"} / container_spec_memory_limit_bytes{namespace="online-boutique",container!="",container!="POD",container!="istio-proxy"}) * 100')
  north_mem_pct=$(prom_query "$NORTH_PROM_URL" \
    'avg(container_memory_working_set_bytes{namespace="online-boutique",container!="",container!="POD",container!="istio-proxy"} / container_spec_memory_limit_bytes{namespace="online-boutique",container!="",container!="POD",container!="istio-proxy"}) * 100')

  west_restarts=$(prom_query "$WEST_PROM_URL" \
    'sum(kube_pod_container_status_restarts_total{namespace="online-boutique"})')
  north_restarts=$(prom_query "$NORTH_PROM_URL" \
    'sum(kube_pod_container_status_restarts_total{namespace="online-boutique"})')

  # Read desired USERS env var from the running loadgenerator pod
  lg_users=$(KUBECONFIG="$WEST_KUBECONFIG" kubectl exec -n "$NAMESPACE" \
    "$(KUBECONFIG="$WEST_KUBECONFIG" kubectl get pod -n "$NAMESPACE" -l app=loadgenerator \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" \
    -- printenv USERS 2>/dev/null || echo "NaN")

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "$phase" "$west_rps" "$north_rps" "$west_p99" "$north_p99" \
    "$west_err" "$north_err" "$west_rep" "$north_rep" \
    "$west_ad_rep" "$north_ad_rep" \
    "$west_cur_rep" "$north_cur_rep" "$west_pcs_rep" "$north_pcs_rep" \
    "$lg_users" "$west_mem_pct" "$north_mem_pct" "$west_restarts" "$north_restarts" \
    >> "$filepath"

  log_info "  W-RPS=${west_rps} N-RPS=${north_rps} | W-P99=${west_p99}ms N-P99=${north_p99}ms | W-fe=${west_rep} N-fe=${north_rep} | W-cur=${west_cur_rep} N-cur=${north_cur_rep} | W-pcs=${west_pcs_rep} N-pcs=${north_pcs_rep} | W-mem=${west_mem_pct}% N-mem=${north_mem_pct}% | N-rst=${north_restarts}"
}

collect_metrics_loop() {
  local filepath="$1" phase="$2" duration="$3"
  local elapsed=0
  while [ "$elapsed" -lt "$duration" ]; do
    collect_metrics_row "$filepath" "$phase"
    sleep "$SAMPLE_INTERVAL_SECONDS"
    elapsed=$((elapsed + SAMPLE_INTERVAL_SECONDS))
  done
}

# ── Cluster readiness ─────────────────────────────────────────────────────────

wait_for_deployments_ready() {
  local timeout="${1:-300}" elapsed=0
  log_info "Waiting for all deployments to be ready (timeout: ${timeout}s)..."
  while [ "$elapsed" -lt "$timeout" ]; do
    local uw en
    uw=$(KUBECONFIG="$WEST_KUBECONFIG" kubectl get deployments -n "$NAMESPACE" \
      -o jsonpath='{range .items[*]}{.status.unavailableReplicas}{"\n"}{end}' 2>/dev/null \
      | (grep -vc "^0*$" || true))
    en=$(KUBECONFIG="$NORTH_KUBECONFIG" kubectl get deployments -n "$NAMESPACE" \
      -o jsonpath='{range .items[*]}{.status.unavailableReplicas}{"\n"}{end}' 2>/dev/null \
      | (grep -vc "^0*$" || true))
    if [ "${uw:-0}" -eq 0 ] && [ "${en:-0}" -eq 0 ]; then
      log_info "All deployments ready."; return 0
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
  log_info "WARNING: some deployments not ready after ${timeout}s — continuing."
}

# ── Load control ──────────────────────────────────────────────────────────────

set_load_users() {
  local users="$1" spawn_rate
  spawn_rate="$((users / 5 > 0 ? users / 5 : 1))"
  log_info "Setting loadgenerator to $users concurrent users (both clusters)..."
  KUBECONFIG="$KARMADA_KUBECONFIG" kubectl set env deployment/loadgenerator \
    -n "$NAMESPACE" USERS="$users" SPAWN_RATE="$spawn_rate"
  sleep 20
}

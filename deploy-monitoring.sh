#!/bin/bash
set -euo pipefail

# --- Configuration ---
NAMESPACE="online-boutique"
WEST_KUBECONFIG="./.generated/kubeconfig-eu-west.yaml"
NORTH_KUBECONFIG="./.generated/kubeconfig-eu-north.yaml"

echo "🚀 Starting Layer 2 Deployment (Monitoring)..."

# 1. Setup Helm Repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 2. Set gp2 as the default StorageClass (required for Prometheus PVCs)
echo "💾 Setting default StorageClass on both clusters..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
KUBECONFIG="$NORTH_KUBECONFIG" kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# 3. Deploy Prometheus/Grafana to West (Belgium)
echo "📦 Deploying Prometheus/Grafana to West cluster..."
sed "s/\${cluster_name}/eu-west/g" ./templates/monitoring/prometheus-values.yaml.tpl > ./.generated/values-west.yaml
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --kubeconfig "$WEST_KUBECONFIG" \
  --namespace "$NAMESPACE" \
  --values "./.generated/values-west.yaml" \
  --values "templates/monitoring/grafana-renderer-values.yaml" \
  --set grafana.enabled=true \
  --set grafana.adminPassword=admin \
  --set grafana.sidecar.datasources.enabled=true \
  --set grafana.sidecar.datasources.label=grafana_datasource \
  --set grafana.sidecar.datasources.defaultDatasourceEnabled=false \
  --set prometheusOperator.admissionWebhooks.enabled=false \
  --set prometheusOperator.admissionWebhooks.patch.enabled=false \
  --set prometheusOperator.tls.enabled=false \
  --wait

# 3. Deploy Prometheus to North (Finland)
echo "📦 Deploying Prometheus to North cluster..."
sed "s/\${cluster_name}/eu-north/g" ./templates/monitoring/prometheus-values.yaml.tpl > ./.generated/values-north.yaml
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --kubeconfig "$NORTH_KUBECONFIG" \
  --namespace "$NAMESPACE" \
  --values "./.generated/values-north.yaml" \
  --values "templates/monitoring/prometheus-north-values.yaml" \
  --set grafana.enabled=false \
  --set prometheusOperator.admissionWebhooks.enabled=false \
  --set prometheusOperator.admissionWebhooks.patch.enabled=false \
  --set prometheusOperator.tls.enabled=false \
  --wait

# 4. Expose North Prometheus via Public LoadBalancer
echo "🌐 Exposing North Prometheus..."
KUBECONFIG="$NORTH_KUBECONFIG" kubectl expose service prometheus-operated \
  --type=LoadBalancer --name=prometheus-public -n "$NAMESPACE" --port=9090 --target-port=9090 || true

echo "⏳ Waiting for North Prometheus IP..."
while true; do
  NORTH_PROM_IP=$(KUBECONFIG="$NORTH_KUBECONFIG" kubectl get svc prometheus-public -n "$NAMESPACE" -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" || echo "")
  if [ ! -z "$NORTH_PROM_IP" ]; then break; fi
  sleep 5
done
echo "✅ North Prometheus IP: $NORTH_PROM_IP"

# 5. Inject Clean DataSources into West Grafana
echo "💉 Injecting cross-cluster datasources..."
cat <<EOF | KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources-clean
  namespace: $NAMESPACE
  labels:
    grafana_datasource: "1"
data:
  manual-datasources.yaml: |
    apiVersion: 1
    datasources:
    - name: eu-west
      type: prometheus
      url: http://prometheus-operated.$NAMESPACE.svc.cluster.local:9090
      access: proxy
      isDefault: true
    - name: eu-north
      type: prometheus
      url: http://$NORTH_PROM_IP:9090
      access: proxy
      isDefault: false
EOF

# 6. Provision experiment dashboards as ConfigMaps (survives pod restarts)
echo "📊 Provisioning experiment dashboards as ConfigMaps..."
for dashboard in experiments/grafana/*.json; do
  [ -f "$dashboard" ] || continue
  name="dashboard-$(basename "$dashboard" .json)"
  KUBECONFIG="$WEST_KUBECONFIG" kubectl create configmap "$name" \
    -n "$NAMESPACE" \
    --from-file="$(basename "$dashboard")=$dashboard" \
    --dry-run=client -o yaml \
  | KUBECONFIG="$WEST_KUBECONFIG" kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f -
  echo "  ✓ $name"
done

# 7. Apply Istio Telemetry, Scrapers, and Permissive Auth
echo "🛠️ Configuring Istio Metrics and Auth..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f manifests/istio-telemetry.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/istio-telemetry.yaml
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f manifests/boutique-monitor.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/boutique-monitor.yaml
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f manifests/monitoring-auth.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/monitoring-auth.yaml

# 8. Expose Grafana
echo "🌐 Exposing Grafana..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl expose deployment prometheus-grafana \
  --type=LoadBalancer --name=grafana-public -n "$NAMESPACE" --port=80 --target-port=3000 || true

echo "⏳ Waiting 45 seconds for Grafana public IP..."
sleep 45

# 9. Force a restart of Grafana to ensure clean state
echo "♻️ Restarting Grafana..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl rollout restart deployment prometheus-grafana -n "$NAMESPACE"
KUBECONFIG="$WEST_KUBECONFIG" kubectl rollout status deployment prometheus-grafana -n "$NAMESPACE" --timeout=120s

# 10. Push experiment dashboards via API (fallback — ConfigMaps above are the primary mechanism)
echo "📊 Pushing experiment dashboards to Grafana..."
GRAFANA_HOST=""
for i in $(seq 1 24); do
  GRAFANA_HOST=$(KUBECONFIG="$WEST_KUBECONFIG" kubectl get svc grafana-public \
    -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$GRAFANA_HOST" ] && break
  sleep 5
done

if [ -n "$GRAFANA_HOST" ]; then
  for i in $(seq 1 12); do
    curl -sf "http://admin:admin@${GRAFANA_HOST}/api/health" &>/dev/null && break
    sleep 5
  done
  for dashboard in experiments/grafana/*.json; do
    [ -f "$dashboard" ] || continue
    name=$(basename "$dashboard")
    result=$(curl -sf -X POST "http://admin:admin@${GRAFANA_HOST}/api/dashboards/db" \
      -H "Content-Type: application/json" \
      -d "{\"dashboard\": $(cat "$dashboard"), \"overwrite\": true, \"folderId\": 0}" 2>/dev/null || true)
    url=$(echo "$result" | jq -r '.url // empty' 2>/dev/null || true)
    if [ -n "$url" ]; then
      echo "  ✓ $name → http://${GRAFANA_HOST}${url}"
    else
      echo "  ✗ Failed to push $name"
    fi
  done
else
  echo "⚠️  Grafana LoadBalancer not ready — dashboards not pushed. Re-run deploy-monitoring.sh or push manually."
fi

echo "✨ Layer 2 Monitoring Deployed Successfully!"
echo "------------------------------------------------"
GRAFANA_IP=$(KUBECONFIG="$WEST_KUBECONFIG" kubectl get svc grafana-public -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' || echo "PENDING")
echo "Grafana URL: http://$GRAFANA_IP"
echo "Password: admin"

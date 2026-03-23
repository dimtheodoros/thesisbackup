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

# 2. Deploy Prometheus/Grafana to West (Belgium)
echo "📦 Deploying Prometheus/Grafana to West cluster..."
sed "s/\${cluster_name}/eu-west/g" ./templates/monitoring/prometheus-values.yaml.tpl > ./.generated/values-west.yaml
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --kubeconfig "$WEST_KUBECONFIG" \
  --namespace "$NAMESPACE" \
  --values "./.generated/values-west.yaml" \
  --set grafana.enabled=true \
  --set grafana.adminPassword=admin \
  --set grafana.sidecar.datasources.enabled=true \
  --set grafana.sidecar.datasources.label=grafana_datasource \
  --set grafana.sidecar.datasources.defaultDatasourceEnabled=false \
  --wait

# 3. Deploy Prometheus to North (Finland)
echo "📦 Deploying Prometheus to North cluster..."
sed "s/\${cluster_name}/eu-north/g" ./templates/monitoring/prometheus-values.yaml.tpl > ./.generated/values-north.yaml
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --kubeconfig "$NORTH_KUBECONFIG" \
  --namespace "$NAMESPACE" \
  --values "./.generated/values-north.yaml" \
  --set grafana.enabled=false \
  --wait

# 4. Expose North Prometheus via Public LoadBalancer
echo "🌐 Exposing North Prometheus..."
KUBECONFIG="$NORTH_KUBECONFIG" kubectl expose service prometheus-operated \
  --type=LoadBalancer --name=prometheus-public -n "$NAMESPACE" --port=9090 --target-port=9090 || true

echo "⏳ Waiting for North Prometheus IP..."
while true; do
  NORTH_PROM_IP=$(KUBECONFIG="$NORTH_KUBECONFIG" kubectl get svc prometheus-public -n "$NAMESPACE" -o jsonpath="{.status.loadBalancer.ingress[0].ip}" || echo "")
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

# 6. Apply Istio Telemetry, Scrapers, and Permissive Auth
echo "🛠️ Configuring Istio Metrics and Auth..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f manifests/istio-telemetry.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/istio-telemetry.yaml
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f manifests/boutique-monitor.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/boutique-monitor.yaml
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f manifests/monitoring-auth.yaml
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/monitoring-auth.yaml

# 7. Expose Grafana
echo "🌐 Exposing Grafana..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl expose deployment prometheus-grafana \
  --type=LoadBalancer --name=grafana-public -n "$NAMESPACE" --port=80 --target-port=3000 || true

# 8. Force a restart of Grafana to ensure clean state
echo "♻️ Restarting Grafana..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl rollout restart deployment prometheus-grafana -n "$NAMESPACE"

echo "✨ Layer 2 Monitoring Deployed Successfully!"
echo "------------------------------------------------"
echo "Grafana URL: http://$(KUBECONFIG="$WEST_KUBECONFIG" kubectl get svc grafana-public -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "Password: admin"

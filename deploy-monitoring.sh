#!/bin/bash
set -euo pipefail

# 1. Setup Helm Repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 2. Deploy Prometheus to West (Belgium)
echo "Deploying Prometheus to West cluster..."
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --kubeconfig "./.generated/kubeconfig-eu-west.yaml" \
  --namespace "online-boutique" \
  --values "./templates/monitoring/prometheus-values.yaml.tpl" \
  --set prometheus.prometheusSpec.externalLabels.cluster="eu-west" \
  --set grafana.enabled=true \
  --set grafana.podAnnotations."sidecar\.istio\.io/inject"="false" \
  --wait

# 3. Deploy Prometheus to North (Finland)
echo "Deploying Prometheus to North cluster..."
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --kubeconfig "./.generated/kubeconfig-eu-north.yaml" \
  --namespace "online-boutique" \
  --values "./templates/monitoring/prometheus-values.yaml.tpl" \
  --set prometheus.prometheusSpec.externalLabels.cluster="eu-north" \
  --set grafana.enabled=false \
  --wait

# 4. Apply Istio Telemetry and ServiceMonitor
echo "Applying Istio Telemetry and ServiceMonitor..."
KUBECONFIG="./.generated/kubeconfig-eu-west.yaml" kubectl apply -f manifests/istio-telemetry.yaml
KUBECONFIG="./.generated/kubeconfig-eu-north.yaml" kubectl apply -f manifests/istio-telemetry.yaml
KUBECONFIG="./.generated/kubeconfig-eu-west.yaml" kubectl apply -f manifests/boutique-monitor.yaml
KUBECONFIG="./.generated/kubeconfig-eu-north.yaml" kubectl apply -f manifests/boutique-monitor.yaml

# 5. Apply Permissive Auth for Scrapers
echo "Applying Permissive PeerAuthentication..."
KUBECONFIG="./.generated/kubeconfig-eu-west.yaml" kubectl apply -f manifests/monitoring-auth.yaml
KUBECONFIG="./.generated/kubeconfig-eu-north.yaml" kubectl apply -f manifests/monitoring-auth.yaml

# 6. Create Public LoadBalancer for Grafana
echo "Exposing Grafana via public LoadBalancer..."
KUBECONFIG="./.generated/kubeconfig-eu-west.yaml" kubectl expose deployment prometheus-grafana \
  --type=LoadBalancer --name=grafana-public -n online-boutique --port=80 --target-port=3000 || true

echo "Monitoring stack (Layer 2) deployed successfully!"

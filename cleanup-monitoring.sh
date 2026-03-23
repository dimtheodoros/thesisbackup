#!/bin/bash
set -euo pipefail

# --- Configuration ---
NAMESPACE="online-boutique"
WEST_KUBECONFIG="./.generated/kubeconfig-eu-west.yaml"
NORTH_KUBECONFIG="./.generated/kubeconfig-eu-north.yaml"

echo "🧹 Starting Layer 2 Cleanup (Monitoring)..."

# 1. Uninstall Helm Releases
echo "🗑️ Uninstalling Prometheus from West..."
helm uninstall prometheus --kubeconfig "$WEST_KUBECONFIG" --namespace "$NAMESPACE" || true

echo "🗑️ Uninstalling Prometheus from North..."
helm uninstall prometheus --kubeconfig "$NORTH_KUBECONFIG" --namespace "$NAMESPACE" || true

# 2. Delete Public Services
echo "🌐 Removing public LoadBalancers..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl delete svc grafana-public -n "$NAMESPACE" --ignore-not-found
KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete svc prometheus-public -n "$NAMESPACE" --ignore-not-found

# 3. Delete ConfigMaps and Auth
echo "📁 Removing configuration and auth..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl delete configmap grafana-datasources-clean -n "$NAMESPACE" --ignore-not-found
KUBECONFIG="$WEST_KUBECONFIG" kubectl delete peerauthentication online-boutique-permissive -n "$NAMESPACE" --ignore-not-found
KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete peerauthentication online-boutique-permissive -n "$NAMESPACE" --ignore-not-found

# 4. Delete Telemetry and Monitors
echo "🛠️ Removing Istio Telemetry and ServiceMonitors..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl delete telemetry mesh-default -n istio-system --ignore-not-found
KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete telemetry mesh-default -n istio-system --ignore-not-found
KUBECONFIG="$WEST_KUBECONFIG" kubectl delete servicemonitor boutique-monitor -n "$NAMESPACE" --ignore-not-found
KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete servicemonitor boutique-monitor -n "$NAMESPACE" --ignore-not-found

echo "✨ Layer 2 Monitoring cleaned up successfully!"

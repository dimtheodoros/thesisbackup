#!/bin/bash
# cleanup-stornx.sh — Remove StornX OptiBalancer from both clusters
#
# Uninstalls StornX and kube-netlag, deletes StornX-managed DestinationRules,
# and restores the original static locality DestinationRules.
# Run this BEFORE cleanup-monitoring.sh.
set -euo pipefail

WEST_KUBECONFIG="./.generated/kubeconfig-eu-west.yaml"
NORTH_KUBECONFIG="./.generated/kubeconfig-eu-north.yaml"
NAMESPACE="online-boutique"
STORNX_NS="stornx"

# Service names that StornX's OptiBalancer creates DRs for
# (named after the Istio destination_service_name, without the -locality suffix)
STORNX_DRS=(
  frontend
  cartservice
  checkoutservice
  currencyservice
  adservice
  productcatalogservice
  recommendationservice
  emailservice
  paymentservice
  shippingservice
  redis-cart
)

echo "Cleaning up StornX from both clusters..."

# ---------------------------------------------------------------------------
# 1. Remove Prometheus federation from eu-west.
#    Reverts the additionalScrapeConfigs patch on the Prometheus CR and deletes
#    the Secret. Must run before monitoring cleanup so Prometheus stops trying
#    to reach the (soon-to-be-gone) eu-north endpoint.
# ---------------------------------------------------------------------------
echo "Removing Prometheus federation from eu-west..."
PROM_CR=$(KUBECONFIG="$WEST_KUBECONFIG" kubectl get prometheus \
  -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$PROM_CR" ]; then
  KUBECONFIG="$WEST_KUBECONFIG" kubectl patch prometheus "$PROM_CR" \
    -n "$NAMESPACE" --type=merge \
    -p '{"spec":{"additionalScrapeConfigs":null}}' 2>/dev/null || true
fi
KUBECONFIG="$WEST_KUBECONFIG" kubectl delete secret stornx-federation-scrape-config \
  -n "$NAMESPACE" --ignore-not-found=true

# ---------------------------------------------------------------------------
# 2. Uninstall StornX Helm release (removes StornX pod, kube-netlag DaemonSet,
#    RBAC, ServiceAccount, PVC, and bootstrap CronJob)
# ---------------------------------------------------------------------------
echo "Uninstalling StornX Helm release from eu-west..."
helm uninstall stornx --kubeconfig "$WEST_KUBECONFIG" --namespace "$STORNX_NS" 2>/dev/null || true

echo "Uninstalling StornX Helm release from eu-north..."
helm uninstall stornx --kubeconfig "$NORTH_KUBECONFIG" --namespace "$STORNX_NS" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Delete stornx namespace (cleans up any leftover resources including
#    the bootstrap CronJob, its RBAC, and kube-netlag DaemonSet)
# ---------------------------------------------------------------------------
echo "Deleting '$STORNX_NS' namespace from eu-west..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl delete namespace "$STORNX_NS" --ignore-not-found=true

echo "Deleting '$STORNX_NS' namespace from eu-north..."
KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete namespace "$STORNX_NS" --ignore-not-found=true

# ---------------------------------------------------------------------------
# 4. Remove StornX-managed DestinationRules from the online-boutique namespace
# ---------------------------------------------------------------------------
echo "Removing StornX-managed DestinationRules from eu-west..."
for dr in "${STORNX_DRS[@]}"; do
  KUBECONFIG="$WEST_KUBECONFIG" kubectl delete destinationrule "$dr" -n "$NAMESPACE" --ignore-not-found=true
done

echo "Removing StornX-managed DestinationRules from eu-north..."
for dr in "${STORNX_DRS[@]}"; do
  KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete destinationrule "$dr" -n "$NAMESPACE" --ignore-not-found=true
done

# ---------------------------------------------------------------------------
# 5. Remove the PodMonitors (kube-netlag and Istio graph scraper)
# ---------------------------------------------------------------------------
echo "Removing PodMonitors from eu-west..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl delete podmonitor kube-netlag -n "$NAMESPACE" --ignore-not-found=true
KUBECONFIG="$WEST_KUBECONFIG" kubectl delete podmonitor boutique-stornx-graph -n "$NAMESPACE" --ignore-not-found=true

echo "Removing PodMonitors from eu-north..."
KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete podmonitor kube-netlag -n "$NAMESPACE" --ignore-not-found=true
KUBECONFIG="$NORTH_KUBECONFIG" kubectl delete podmonitor boutique-stornx-graph -n "$NAMESPACE" --ignore-not-found=true

# ---------------------------------------------------------------------------
# 6. Restore original static locality DestinationRules
# ---------------------------------------------------------------------------
echo "Restoring original locality DestinationRules on eu-west..."
KUBECONFIG="$WEST_KUBECONFIG" kubectl apply -f manifests/online-boutique-locality.yaml

echo "Restoring original locality DestinationRules on eu-north..."
KUBECONFIG="$NORTH_KUBECONFIG" kubectl apply -f manifests/online-boutique-locality.yaml

echo ""
echo "StornX cleanup complete. Original locality DestinationRules restored."

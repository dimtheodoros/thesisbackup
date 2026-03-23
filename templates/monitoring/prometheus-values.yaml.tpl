prometheus:
  prometheusSpec:
    externalLabels:
      cluster: ${cluster_name}
    # This ensures external labels are included in every query result
    query:
      lookbackDelta: 5m
    podMetadata:
      annotations:
        sidecar.istio.io/inject: "false"
    resources:
      requests:
        cpu: 100m
        memory: 512Mi
      limits:
        cpu: 500m
        memory: 1024Mi
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
    additionalScrapeConfigs:
      - job_name: 'istio-sidecars'
        kubernetes_sd_configs:
        - role: pod
        relabel_configs:
        - source_labels: [__meta_kubernetes_pod_container_name]
          action: keep
          regex: istio-proxy
        - source_labels: [__address__]
          action: replace
          target_label: __address__
          regex: (.*):.*
          replacement: $1:15020
        - source_labels: [__meta_kubernetes_pod_name]
          target_label: pod
        - source_labels: [__meta_kubernetes_namespace]
          target_label: namespace
        metrics_path: /stats/prometheus
nodeExporter:
  enabled: true
kubeStateMetrics:
  enabled: true
grafana:
  enabled: false

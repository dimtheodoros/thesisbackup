adminPassword: admin
grafana.ini:
  auth.anonymous:
    enabled: true
    org_role: Admin
sidecar:
  datasources:
    enabled: true
    label: grafana_datasource
podAnnotations:
  sidecar.istio.io/inject: "true"
additionalDataSources:
  - name: eu-west
    type: prometheus
    url: http://prometheus-operated.online-boutique.svc.cluster.local:9090
    access: proxy
    isDefault: false
  - name: eu-north
    type: prometheus
    url: http://prometheus-north.global:9090
    access: proxy
    isDefault: false

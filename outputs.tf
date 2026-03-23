output "west_cluster_name" {
  value = var.cluster_west_name
}

output "north_cluster_name" {
  value = var.cluster_north_name
}

output "app_url_belgium" {
  value = "http://${data.kubernetes_service.ingress_west.status[0].load_balancer[0].ingress[0].ip}"
}

output "app_url_finland" {
  value = "http://${data.kubernetes_service.ingress_north.status[0].load_balancer[0].ingress[0].ip}"
}

output "grafana_url" {
  value = try("http://${data.kubernetes_service.grafana_public.status[0].load_balancer[0].ingress[0].ip}", "Not deployed yet")
}

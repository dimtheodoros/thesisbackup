output "west_cluster_name" {
  value = google_container_cluster.west.name
}

output "north_cluster_name" {
  value = google_container_cluster.north.name
}

output "west_api_endpoint" {
  value = google_container_cluster.west.endpoint
}

output "north_api_endpoint" {
  value = google_container_cluster.north.endpoint
}

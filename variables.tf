variable "region_west" {
  type    = string
  default = "eu-west-1"
}

variable "zones_west" {
  type    = list(string)
  default = ["eu-west-1a", "eu-west-1b"]
}

variable "region_north" {
  type    = string
  default = "eu-north-1"
}

variable "zones_north" {
  type    = list(string)
  default = ["eu-north-1a", "eu-north-1b"]
}

variable "cluster_west_name" {
  type    = string
  default = "eu-west"
}

variable "cluster_north_name" {
  type    = string
  default = "eu-north"
}

variable "node_machine_type" {
  type    = string
  default = "t3.large"
}

variable "node_disk_gb" {
  type    = number
  default = 50
}

variable "min_nodes" {
  type    = number
  default = 1
}

variable "max_nodes" {
  type    = number
  default = 3
}

# For regional clusters, this is effectively per-zone node_count within the node pool.
variable "nodes_per_zone" {
  type    = number
  default = 3
}

variable "istio_version" {
  type    = string
  default = "1.28.3"
}

variable "mesh_id" {
  type    = string
  default = "shared-mesh"
}

variable "network_west" {
  type    = string
  default = "eu-west-network"
}

variable "network_north" {
  type    = string
  default = "eu-north-network"
}

variable "online_boutique_namespace" {
  type    = string
  default = "online-boutique"
}


# Path to your local Online Boutique Helm chart directory
# (the folder that contains Chart.yaml).
variable "online_boutique_chart_path" {
  type    = string
  default = "./OnlineBoutique app/helm-chart"
}

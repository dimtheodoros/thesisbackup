provider "google" {
  project = var.project_id
  region  = var.region_west
}

data "google_client_config" "default" {}

resource "google_compute_firewall" "allow_istio_cross_cluster" {
  name    = "allow-istio-cross-cluster"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["15443", "15021", "15012", "15017", "15010"]
  }

  source_ranges = ["0.0.0.0/0"]
}

############################################
# GKE clusters
############################################

resource "google_container_cluster" "west" {
  name     = var.cluster_west_name
  location = var.region_west

  node_locations = var.zones_west

  release_channel {
    channel = var.gke_release_channel
  }

  # VPC-native / IP aliasing
  ip_allocation_policy {}

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false
}

resource "google_container_node_pool" "west_nodes" {
  name     = "${var.cluster_west_name}-np"
  cluster  = google_container_cluster.west.name
  location = google_container_cluster.west.location

  node_locations = var.zones_west
  node_count     = var.nodes_per_zone

  autoscaling {
    min_node_count = var.min_nodes
    max_node_count = var.max_nodes
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_gb

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

resource "google_container_cluster" "north" {
  name     = var.cluster_north_name
  location = var.region_north

  node_locations = var.zones_north

  release_channel {
    channel = var.gke_release_channel
  }

  ip_allocation_policy {}

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false
}

resource "google_container_node_pool" "north_nodes" {
  name     = "${var.cluster_north_name}-np"
  cluster  = google_container_cluster.north.name
  location = google_container_cluster.north.location

  node_locations = var.zones_north
  node_count     = var.nodes_per_zone

  autoscaling {
    min_node_count = var.min_nodes
    max_node_count = var.max_nodes
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_gb

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

############################################
# Cluster connection details
############################################

locals {
  west_host  = "https://${google_container_cluster.west.endpoint}"
  north_host = "https://${google_container_cluster.north.endpoint}"

  west_ca  = base64decode(google_container_cluster.west.master_auth[0].cluster_ca_certificate)
  north_ca = base64decode(google_container_cluster.north.master_auth[0].cluster_ca_certificate)
}

############################################
# Kubernetes providers (one per cluster)
# (Not used for namespaces anymore; kept harmlessly.)
############################################

provider "kubernetes" {
  alias                  = "west"
  host                   = local.west_host
  cluster_ca_certificate = local.west_ca
  token                  = data.google_client_config.default.access_token
}

provider "kubernetes" {
  alias                  = "north"
  host                   = local.north_host
  cluster_ca_certificate = local.north_ca
  token                  = data.google_client_config.default.access_token
}

############################################
# Helm providers (one per cluster)
############################################

provider "helm" {
  alias = "west"

  kubernetes = {
    host                   = local.west_host
    cluster_ca_certificate = local.west_ca
    token                  = data.google_client_config.default.access_token
  }
}

provider "helm" {
  alias = "north"

  kubernetes = {
    host                   = local.north_host
    cluster_ca_certificate = local.north_ca
    token                  = data.google_client_config.default.access_token
  }
}

############################################
# Kubeconfig files for local-exec (istioctl/kubectl)
############################################

resource "local_file" "kubeconfig_west" {
  filename = "${path.module}/.generated/kubeconfig-${var.cluster_west_name}.yaml"
  content = templatefile("${path.module}/templates/kubeconfig", {
    ca           = google_container_cluster.west.master_auth[0].cluster_ca_certificate
    server       = local.west_host
    cluster_name = var.cluster_west_name
    token        = data.google_client_config.default.access_token
  })

  depends_on = [
    google_container_node_pool.west_nodes
  ]
}

resource "local_file" "kubeconfig_north" {
  filename = "${path.module}/.generated/kubeconfig-${var.cluster_north_name}.yaml"
  content = templatefile("${path.module}/templates/kubeconfig", {
    ca           = google_container_cluster.north.master_auth[0].cluster_ca_certificate
    server       = local.north_host
    cluster_name = var.cluster_north_name
    token        = data.google_client_config.default.access_token
  })

  depends_on = [
    google_container_node_pool.north_nodes
  ]
}

############################################
# Namespaces via kubectl (replaces kubernetes_namespace_v1)
############################################

resource "null_resource" "ns_istio_west" {
  depends_on = [local_file.kubeconfig_west]

  triggers = {
    kubeconfig_sha = sha256(local_file.kubeconfig_west.content)
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl get ns istio-system >/dev/null 2>&1 || \
KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl create ns istio-system
EOT
  }
}

resource "null_resource" "ns_istio_north" {
  depends_on = [local_file.kubeconfig_north]

  triggers = {
    kubeconfig_sha = sha256(local_file.kubeconfig_north.content)
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl get ns istio-system >/dev/null 2>&1 || \
KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl create ns istio-system
EOT
  }
}

resource "null_resource" "ns_boutique_west" {
  depends_on = [local_file.kubeconfig_west]

  triggers = {
    kubeconfig_sha = sha256(local_file.kubeconfig_west.content)
    ns_name        = var.online_boutique_namespace
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl get ns ${var.online_boutique_namespace} >/dev/null 2>&1 || \
KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl create ns ${var.online_boutique_namespace}
KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl label ns ${var.online_boutique_namespace} istio-injection=enabled --overwrite
KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl label ns ${var.online_boutique_namespace} topology.istio.io/network=${var.network_west} --overwrite
EOT
  }
}

resource "null_resource" "ns_boutique_north" {
  depends_on = [local_file.kubeconfig_north]

  triggers = {
    kubeconfig_sha = sha256(local_file.kubeconfig_north.content)
    ns_name        = var.online_boutique_namespace
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl get ns ${var.online_boutique_namespace} >/dev/null 2>&1 || \
KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl create ns ${var.online_boutique_namespace}
KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl label ns ${var.online_boutique_namespace} istio-injection=enabled --overwrite
KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl label ns ${var.online_boutique_namespace} topology.istio.io/network=${var.network_north} --overwrite
EOT
  }
}

############################################
# Automated Istio Shared Root CA setup
############################################

# 1. Root CA
resource "tls_private_key" "root" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "root" {
  private_key_pem = tls_private_key.root.private_key_pem

  subject {
    common_name  = "Istio Root CA"
    organization = "Istio"
  }

  validity_period_hours = 87600 # 10 years
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
  ]
}

# 2. Intermediate CA for West
resource "tls_private_key" "west" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "west" {
  private_key_pem = tls_private_key.west.private_key_pem

  subject {
    common_name  = "Istio West Intermediate CA"
    organization = "Istio"
  }
}

resource "tls_locally_signed_cert" "west" {
  cert_request_pem   = tls_cert_request.west.cert_request_pem
  ca_private_key_pem = tls_private_key.root.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.root.cert_pem

  validity_period_hours = 43800 # 5 years
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
  ]
}

# 3. Intermediate CA for North
resource "tls_private_key" "north" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "north" {
  private_key_pem = tls_private_key.north.private_key_pem

  subject {
    common_name  = "Istio North Intermediate CA"
    organization = "Istio"
  }
}

resource "tls_locally_signed_cert" "north" {
  cert_request_pem   = tls_cert_request.north.cert_request_pem
  ca_private_key_pem = tls_private_key.root.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.root.cert_pem

  validity_period_hours = 43800 # 5 years
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
  ]
}

# 4. Create cacerts secret in each cluster
resource "null_resource" "cacerts_west" {
  depends_on = [null_resource.ns_istio_west]

  triggers = {
    ca_cert    = tls_locally_signed_cert.west.cert_pem
    ca_key     = tls_private_key.west.private_key_pem
    root_cert  = tls_self_signed_cert.root.cert_pem
    cert_chain = "${tls_locally_signed_cert.west.cert_pem}${tls_self_signed_cert.root.cert_pem}"
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl delete secret cacerts -n istio-system --ignore-not-found
KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl create secret generic cacerts -n istio-system \
  --from-literal=ca-cert.pem="${self.triggers.ca_cert}" \
  --from-literal=ca-key.pem="${self.triggers.ca_key}" \
  --from-literal=root-cert.pem="${self.triggers.root_cert}" \
  --from-literal=cert-chain.pem="${self.triggers.cert_chain}"
EOT
  }
}

resource "null_resource" "cacerts_north" {
  depends_on = [null_resource.ns_istio_north]

  triggers = {
    ca_cert    = tls_locally_signed_cert.north.cert_pem
    ca_key     = tls_private_key.north.private_key_pem
    root_cert  = tls_self_signed_cert.root.cert_pem
    cert_chain = "${tls_locally_signed_cert.north.cert_pem}${tls_self_signed_cert.root.cert_pem}"
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl delete secret cacerts -n istio-system --ignore-not-found
KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl create secret generic cacerts -n istio-system \
  --from-literal=ca-cert.pem="${self.triggers.ca_cert}" \
  --from-literal=ca-key.pem="${self.triggers.ca_key}" \
  --from-literal=root-cert.pem="${self.triggers.root_cert}" \
  --from-literal=cert-chain.pem="${self.triggers.cert_chain}"
EOT
  }
}

############################################
# Istio install via Helm: base + istiod
############################################

resource "helm_release" "istio_base_west" {
  provider  = helm.west
  name      = "istio-base"
  namespace = "istio-system"

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = var.istio_version

  depends_on = [
    null_resource.ns_istio_west
  ]
}

resource "helm_release" "istio_base_north" {
  provider  = helm.north
  name      = "istio-base"
  namespace = "istio-system"

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = var.istio_version

  depends_on = [
    null_resource.ns_istio_north
  ]
}

locals {
  istiod_values_west = templatefile("${path.module}/templates/istiod-values.yaml", {
    mesh_id      = var.mesh_id
    cluster_name = var.cluster_west_name
    network      = var.network_west
  })

  istiod_values_north = templatefile("${path.module}/templates/istiod-values.yaml", {
    mesh_id      = var.mesh_id
    cluster_name = var.cluster_north_name
    network      = var.network_north
  })
}

resource "helm_release" "istiod_west" {
  provider  = helm.west
  name      = "istiod"
  namespace = "istio-system"

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version

  values = [
    local.istiod_values_west,
    <<-EOT
    meshConfig:
      trustDomain: cluster.local
      enablePrometheusMerge: true
      defaultConfig:
        proxyMetadata:
          ISTIO_META_DNS_CAPTURE: "true"
          ISTIO_META_DNS_AUTO_ALLOCATE: "true"
    EOT
  ]

  depends_on = [
    helm_release.istio_base_west,
    null_resource.cacerts_west
  ]
}

resource "helm_release" "istiod_north" {
  provider  = helm.north
  name      = "istiod"
  namespace = "istio-system"

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version

  values = [
    local.istiod_values_north,
    <<-EOT
    meshConfig:
      trustDomain: cluster.local
      enablePrometheusMerge: true
      defaultConfig:
        proxyMetadata:
          ISTIO_META_DNS_CAPTURE: "true"
          ISTIO_META_DNS_AUTO_ALLOCATE: "true"
    EOT
  ]

  depends_on = [
    helm_release.istio_base_north,
    null_resource.cacerts_north
  ]
}

############################################
# East-west gateways (one per cluster)
############################################

locals {
  eastwest_values_west = templatefile("${path.module}/templates/eastwest-gw-values.yaml", {
    network = var.network_west
  })

  eastwest_values_north = templatefile("${path.module}/templates/eastwest-gw-values.yaml", {
    network = var.network_north
  })
}

resource "helm_release" "eastwest_gw_west" {
  provider  = helm.west
  name      = "istio-eastwestgateway"
  namespace = "istio-system"

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = var.istio_version

  values = [local.eastwest_values_west]

  depends_on = [
    helm_release.istiod_west
  ]
}

resource "helm_release" "eastwest_gw_north" {
  provider  = helm.north
  name      = "istio-eastwestgateway"
  namespace = "istio-system"

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = var.istio_version

  values = [local.eastwest_values_north]

  depends_on = [
    helm_release.istiod_north
  ]
}

############################################
# Ingress gateways (one per cluster)
############################################

resource "helm_release" "istio_ingress_west" {
  provider  = helm.west
  name      = "istio-ingressgateway"
  namespace = "istio-system"

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = var.istio_version

  values = [
    <<-EOT
    labels:
      istio: ingressgateway
    service:
      type: LoadBalancer
    EOT
  ]

  depends_on = [
    helm_release.istiod_west
  ]
}

resource "helm_release" "istio_ingress_north" {
  provider  = helm.north
  name      = "istio-ingressgateway"
  namespace = "istio-system"

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = var.istio_version

  values = [
    <<-EOT
    labels:
      istio: ingressgateway
    service:
      type: LoadBalancer
    EOT
  ]

  depends_on = [
    helm_release.istiod_north
  ]
}

############################################
# Apply YAML manifests via kubectl (replaces kubernetes_manifest)
############################################

resource "null_resource" "apply_expose_services_west" {
  depends_on = [
    helm_release.eastwest_gw_west,
    local_file.kubeconfig_west
  ]

  triggers = {
    expose_services_sha = filesha256("${path.module}/manifests/expose-services.yaml")
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl apply -f "${path.module}/manifests/expose-services.yaml"
EOT
  }
}

resource "null_resource" "apply_expose_services_north" {
  depends_on = [
    helm_release.eastwest_gw_north,
    local_file.kubeconfig_north
  ]

  triggers = {
    expose_services_sha = filesha256("${path.module}/manifests/expose-services.yaml")
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl apply -f "${path.module}/manifests/expose-services.yaml"
EOT
  }
}

############################################
# Remote secret exchange (istioctl + kubectl via Terraform)
############################################

resource "null_resource" "remote_secret_west_to_north" {
  depends_on = [
    helm_release.istiod_west,
    helm_release.istiod_north,
    local_file.kubeconfig_west,
    local_file.kubeconfig_north,
    null_resource.apply_expose_services_west,
    null_resource.apply_expose_services_north
  ]

  triggers = {
    istio_version  = var.istio_version
    west_endpoint  = google_container_cluster.west.endpoint
    north_endpoint = google_container_cluster.north.endpoint
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
export KUBECONFIG="${local_file.kubeconfig_west.filename}"
istioctl create-remote-secret --context "${var.cluster_west_name}" --name "${var.cluster_west_name}" \
  | KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl apply -f -
EOT
  }
}

resource "null_resource" "remote_secret_north_to_west" {
  depends_on = [
    null_resource.remote_secret_west_to_north
  ]

  triggers = {
    istio_version  = var.istio_version
    west_endpoint  = google_container_cluster.west.endpoint
    north_endpoint = google_container_cluster.north.endpoint
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
export KUBECONFIG="${local_file.kubeconfig_north.filename}"
istioctl create-remote-secret --context "${var.cluster_north_name}" --name "${var.cluster_north_name}" \
  | KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl apply -f -
EOT
  }
}

############################################
# Deploy Online Boutique Helm chart to both clusters
############################################

resource "helm_release" "boutique_west" {
  provider  = helm.west
  name      = "online-boutique"
  namespace = var.online_boutique_namespace

  chart = var.online_boutique_chart_path

  values = [
    file("${path.module}/manifests/values-eu-west.yaml")
  ]

  depends_on = [
    null_resource.ns_boutique_west,
    null_resource.remote_secret_north_to_west
  ]
}

resource "helm_release" "boutique_north" {
  provider  = helm.north
  name      = "online-boutique"
  namespace = var.online_boutique_namespace

  chart = var.online_boutique_chart_path

  values = [
    file("${path.module}/manifests/values-eu-north.yaml")
  ]

  depends_on = [
    null_resource.ns_boutique_north,
    null_resource.remote_secret_north_to_west
  ]
}

############################################
# Apply locality + ingress YAMLs via kubectl
############################################

resource "null_resource" "apply_locality_west" {
  depends_on = [
    helm_release.boutique_west,
    local_file.kubeconfig_west
  ]

  triggers = {
    locality_sha = filesha256("${path.module}/manifests/online-boutique-locality.yaml")
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl apply -f "${path.module}/manifests/online-boutique-locality.yaml"
EOT
  }
}

resource "null_resource" "apply_locality_north" {
  depends_on = [
    helm_release.boutique_north,
    local_file.kubeconfig_north
  ]

  triggers = {
    locality_sha = filesha256("${path.module}/manifests/online-boutique-locality.yaml")
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl apply -f "${path.module}/manifests/online-boutique-locality.yaml"
EOT
  }
}

resource "null_resource" "apply_ingress_gateway_west" {
  depends_on = [
    helm_release.boutique_west,
    helm_release.istio_ingress_west,
    local_file.kubeconfig_west
  ]

  triggers = {
    gw_sha = filesha256("${path.module}/manifests/online-boutique-ingress-gateway.yaml")
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl apply -f "${path.module}/manifests/online-boutique-ingress-gateway.yaml"
EOT
  }
}

resource "null_resource" "apply_ingress_gateway_north" {
  depends_on = [
    helm_release.boutique_north,
    helm_release.istio_ingress_north,
    local_file.kubeconfig_north
  ]

  triggers = {
    gw_sha = filesha256("${path.module}/manifests/online-boutique-ingress-gateway.yaml")
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl apply -f "${path.module}/manifests/online-boutique-ingress-gateway.yaml"
EOT
  }
}

resource "null_resource" "apply_ingress_vs_west" {
  depends_on = [
    null_resource.apply_ingress_gateway_west,
    local_file.kubeconfig_west
  ]

  triggers = {
    vs_sha = filesha256("${path.module}/manifests/online-boutique-ingress-virtualservice.yaml")
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_west.filename}" kubectl apply -f "${path.module}/manifests/online-boutique-ingress-virtualservice.yaml"
EOT
  }
}

resource "null_resource" "apply_ingress_vs_north" {
  depends_on = [
    null_resource.apply_ingress_gateway_north,
    local_file.kubeconfig_north
  ]

  triggers = {
    vs_sha = filesha256("${path.module}/manifests/online-boutique-ingress-virtualservice.yaml")
  }

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
KUBECONFIG="${local_file.kubeconfig_north.filename}" kubectl apply -f "${path.module}/manifests/online-boutique-ingress-virtualservice.yaml"
EOT
  }
}

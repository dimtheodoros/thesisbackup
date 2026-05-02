provider "aws" {
  region = var.region_west
}

provider "aws" {
  alias  = "north"
  region = var.region_north
}

data "aws_eks_cluster" "west" {
  name = aws_eks_cluster.west.name
}

data "aws_eks_cluster_auth" "west" {
  name = aws_eks_cluster.west.name
}

data "aws_eks_cluster" "north" {
  provider = aws.north
  name     = aws_eks_cluster.north.name
}

data "aws_eks_cluster_auth" "north" {
  provider = aws.north
  name     = aws_eks_cluster.north.name
}

data "aws_vpc" "west" {
  default = true
}

data "aws_subnets" "west" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.west.id]
  }
}

data "aws_vpc" "north" {
  provider = aws.north
  default  = true
}

data "aws_subnets" "north" {
  provider = aws.north
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.north.id]
  }
}

resource "aws_security_group" "istio_cross_cluster_west" {
  name        = "istio-cross-cluster-west"
  description = "Allow Istio cross-cluster traffic"
  vpc_id      = data.aws_vpc.west.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 15010
    to_port     = 15010
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 15012
    to_port     = 15012
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 15017
    to_port     = 15017
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 15021
    to_port     = 15021
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 15443
    to_port     = 15443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "istio_cross_cluster_north" {
  provider    = aws.north
  name        = "istio-cross-cluster-north"
  description = "Allow Istio cross-cluster traffic"
  vpc_id      = data.aws_vpc.north.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 15010
    to_port     = 15010
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 15012
    to_port     = 15012
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 15017
    to_port     = 15017
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 15021
    to_port     = 15021
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 15443
    to_port     = 15443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################################
# IAM roles for EKS (shared between clusters)
############################################

resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_role.name
}

############################################
# EKS clusters
############################################

resource "aws_eks_cluster" "west" {
  name     = var.cluster_west_name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = "1.31"

  vpc_config {
    subnet_ids         = data.aws_subnets.west.ids
    security_group_ids = [aws_security_group.istio_cross_cluster_west.id]
  }

  kubernetes_network_config {
    service_ipv4_cidr = "172.20.0.0/16"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

resource "aws_eks_node_group" "west" {
  cluster_name    = aws_eks_cluster.west.name
  node_group_name = "${var.cluster_west_name}-ng"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = data.aws_subnets.west.ids
  instance_types  = [var.node_machine_type]

  scaling_config {
    desired_size = var.nodes_per_zone
    min_size     = var.min_nodes
    max_size     = var.max_nodes
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]
}

resource "aws_eks_cluster" "north" {
  provider = aws.north
  name     = var.cluster_north_name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = "1.31"

  vpc_config {
    subnet_ids         = data.aws_subnets.north.ids
    security_group_ids = [aws_security_group.istio_cross_cluster_north.id]
  }

  kubernetes_network_config {
    service_ipv4_cidr = "172.20.0.0/16"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

resource "aws_eks_node_group" "north" {
  provider        = aws.north
  cluster_name    = aws_eks_cluster.north.name
  node_group_name = "${var.cluster_north_name}-ng"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = data.aws_subnets.north.ids
  instance_types  = [var.node_machine_type]

  scaling_config {
    desired_size = var.nodes_per_zone
    min_size     = var.min_nodes
    max_size     = var.max_nodes
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]
}

############################################
# IRSA: OIDC providers + EBS CSI driver
############################################

data "tls_certificate" "eks_west" {
  url = data.aws_eks_cluster.west.identity[0].oidc[0].issuer
}

data "tls_certificate" "eks_north" {
  url = data.aws_eks_cluster.north.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "west" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_west.certificates[0].sha1_fingerprint]
  url             = data.aws_eks_cluster.west.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "north" {
  provider        = aws.north
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_north.certificates[0].sha1_fingerprint]
  url             = data.aws_eks_cluster.north.identity[0].oidc[0].issuer
}

resource "aws_iam_role" "ebs_csi_role_west" {
  name = "eks-ebs-csi-west"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.west.arn
      }
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.west.url, "https://", "")}:aud" = "sts.amazonaws.com"
          "${replace(aws_iam_openid_connect_provider.west.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_policy_west" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_role_west.name
}

resource "aws_iam_role" "ebs_csi_role_north" {
  name = "eks-ebs-csi-north"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.north.arn
      }
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.north.url, "https://", "")}:aud" = "sts.amazonaws.com"
          "${replace(aws_iam_openid_connect_provider.north.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_policy_north" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_role_north.name
}

resource "aws_eks_addon" "ebs_csi_west" {
  cluster_name             = aws_eks_cluster.west.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_role_west.arn

  depends_on = [aws_eks_node_group.west]
}

resource "aws_eks_addon" "ebs_csi_north" {
  provider                 = aws.north
  cluster_name             = aws_eks_cluster.north.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_role_north.arn

  depends_on = [aws_eks_node_group.north]
}

############################################
# Cluster connection details
############################################

locals {
  west_host  = data.aws_eks_cluster.west.endpoint
  north_host = data.aws_eks_cluster.north.endpoint

  west_ca  = base64decode(data.aws_eks_cluster.west.certificate_authority[0].data)
  north_ca = base64decode(data.aws_eks_cluster.north.certificate_authority[0].data)
}

############################################
# Kubernetes providers (one per cluster)
# (Not used for namespaces anymore; kept harmlessly.)
############################################

provider "kubernetes" {
  alias                  = "west"
  host                   = local.west_host
  cluster_ca_certificate = local.west_ca
  token                  = data.aws_eks_cluster_auth.west.token
}

provider "kubernetes" {
  alias                  = "north"
  host                   = local.north_host
  cluster_ca_certificate = local.north_ca
  token                  = data.aws_eks_cluster_auth.north.token
}

############################################
# Helm providers (one per cluster)
############################################

provider "helm" {
  alias = "west"

  kubernetes = {
    host                   = local.west_host
    cluster_ca_certificate = local.west_ca
    token                  = data.aws_eks_cluster_auth.west.token
  }
}

provider "helm" {
  alias = "north"

  kubernetes = {
    host                   = local.north_host
    cluster_ca_certificate = local.north_ca
    token                  = data.aws_eks_cluster_auth.north.token
  }
}

############################################
# Kubeconfig files for local-exec (istioctl/kubectl)
############################################

resource "local_file" "kubeconfig_west" {
  filename = "${path.module}/.generated/kubeconfig-${var.cluster_west_name}.yaml"
  content = templatefile("${path.module}/templates/kubeconfig", {
    ca           = data.aws_eks_cluster.west.certificate_authority[0].data
    server       = local.west_host
    cluster_name = var.cluster_west_name
    region       = var.region_west
  })

  depends_on = [
    aws_eks_node_group.west
  ]
}

resource "local_file" "kubeconfig_north" {
  filename = "${path.module}/.generated/kubeconfig-${var.cluster_north_name}.yaml"
  content = templatefile("${path.module}/templates/kubeconfig", {
    ca           = data.aws_eks_cluster.north.certificate_authority[0].data
    server       = local.north_host
    cluster_name = var.cluster_north_name
    region       = var.region_north
  })

  depends_on = [
    aws_eks_node_group.north
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
    west_endpoint  = aws_eks_cluster.west.endpoint
    north_endpoint = aws_eks_cluster.north.endpoint
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
    west_endpoint  = aws_eks_cluster.west.endpoint
    north_endpoint = aws_eks_cluster.north.endpoint
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

############################################
# Data sources for correct Outputs
############################################

data "kubernetes_service" "ingress_west" {
  provider = kubernetes.west
  metadata {
    name      = "istio-ingressgateway"
    namespace = "istio-system"
  }
  depends_on = [helm_release.istio_ingress_west]
}

data "kubernetes_service" "ingress_north" {
  provider = kubernetes.north
  metadata {
    name      = "istio-ingressgateway"
    namespace = "istio-system"
  }
  depends_on = [helm_release.istio_ingress_north]
}


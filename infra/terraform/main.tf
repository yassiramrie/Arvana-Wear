terraform {
  required_version = ">= 1.10.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Application = "arvana-wear"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_eks_addon_version" "cloudwatch" {
  addon_name         = "amazon-cloudwatch-observability"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

data "aws_eks_addon_version" "pod_identity" {
  addon_name         = "eks-pod-identity-agent"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

locals {
  name        = "${var.name_prefix}-${var.environment}"
  azs         = slice(data.aws_availability_zones.available.names, 0, 3)
  oidc_issuer = trimprefix(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://")
  subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
  }
}

resource "terraform_data" "validate_node_group_scaling" {
  input = {
    minimum = var.node_min_size
    desired = var.node_desired_size
    maximum = var.node_max_size
  }

  lifecycle {
    precondition {
      condition     = var.node_min_size <= var.node_desired_size && var.node_desired_size <= var.node_max_size
      error_message = "Node scaling must satisfy node_min_size <= node_desired_size <= node_max_size."
    }
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  map_public_ip_on_launch = true
  tags = merge(local.subnet_tags, {
    Name                     = "${local.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)
  tags = merge(local.subnet_tags, {
    Name                              = "${local.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.main]
  tags          = { Name = "${local.name}-nat" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-private" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "eks_cluster" {
  name_prefix = "${local.name}-cluster-"
  description = "EKS control plane and worker communication"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Worker nodes and control plane"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
    # The node-to-control-plane ingress rule is managed separately below.
    ignore_changes = [ingress]
  }
}

resource "aws_kms_key" "eks" {
  description             = "EKS Kubernetes secret encryption for ${local.name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = toset(["application", "dataplane", "host", "performance"])

  name              = "/aws/containerinsights/${local.name}/${each.value}"
  retention_in_days = 30
}

resource "aws_iam_role" "eks_cluster" {
  name = "${local.name}-eks-cluster"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = local.name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster,
    aws_cloudwatch_log_group.eks_cluster,
  ]
  tags = { Name = local.name }

  lifecycle {
    precondition {
      condition     = length(var.cluster_endpoint_public_access_cidrs) > 0
      error_message = "Set cluster_endpoint_public_access_cidrs to your trusted public IP CIDR; public endpoint access must not be open to the internet."
    }
  }
}

resource "aws_iam_role" "eks_nodes" {
  name = "${local.name}-eks-nodes"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
  ])
  role       = aws_iam_role.eks_nodes.name
  policy_arn = each.value
}

resource "aws_security_group" "eks_nodes" {
  name_prefix = "${local.name}-nodes-"
  description = "Managed worker node traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Worker node to worker node traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    description     = "Control plane to worker nodes"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.eks_cluster.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "cluster_to_nodes" {
  type                     = "ingress"
  description              = "Worker nodes to EKS control plane"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_nodes.id
}

resource "aws_launch_template" "eks_nodes" {
  name_prefix            = "${local.name}-workers-"
  vpc_security_group_ids = [aws_security_group.eks_nodes.id]
  update_default_version = true
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name}-workers"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = var.node_instance_types
  capacity_type   = "ON_DEMAND"

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = {
    "k8s.io/cluster-autoscaler/enabled"       = "true"
    "k8s.io/cluster-autoscaler/${local.name}" = "owned"
    "kubernetes.io/cluster/${local.name}"     = "owned"
  }

  depends_on = [aws_iam_role_policy_attachment.eks_nodes]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

resource "aws_eks_addon" "cloudwatch" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "amazon-cloudwatch-observability"
  addon_version = data.aws_eks_addon_version.cloudwatch.version
  depends_on    = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = data.aws_eks_addon_version.pod_identity.version
  depends_on    = [aws_eks_node_group.main]
}

data "aws_iam_policy_document" "load_balancer_controller_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "load_balancer_controller" {
  name               = "${local.name}-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.load_balancer_controller_assume.json
}

resource "aws_iam_policy" "load_balancer_controller" {
  name   = "${local.name}-load-balancer-controller"
  policy = file("${path.module}/aws-load-balancer-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

resource "aws_eks_pod_identity_association" "load_balancer_controller" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.load_balancer_controller.arn

  depends_on = [aws_eks_addon.pod_identity]
}

resource "aws_autoscaling_group_tag" "cluster_autoscaler" {
  count = 1

  autoscaling_group_name = aws_eks_node_group.main.resources[0].autoscaling_groups[0].name
  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }
}

resource "aws_autoscaling_group_tag" "cluster_autoscaler_name" {
  count = 1

  autoscaling_group_name = aws_eks_node_group.main.resources[0].autoscaling_groups[0].name
  tag {
    key                 = "k8s.io/cluster-autoscaler/${local.name}"
    value               = "owned"
    propagate_at_launch = false
  }
}

resource "aws_ecr_repository" "api" {
  name                 = "${local.name}-api"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${local.name}-frontend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-database"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "${local.name}-database" }
}

resource "aws_cloudwatch_log_group" "rds" {
  for_each = toset(["postgresql", "upgrade"])

  name              = "/aws/rds/instance/${local.name}-postgres/${each.value}"
  retention_in_days = 30
}

resource "aws_security_group" "database" {
  name_prefix = "${local.name}-database-"
  description = "PostgreSQL access only from the EKS cluster"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from EKS cluster"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "random_password" "database_admin" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "database_app" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "jwt" {
  length  = 48
  special = false
}

resource "aws_db_instance" "main" {
  identifier                      = "${local.name}-postgres"
  engine                          = "postgres"
  engine_version                  = var.postgres_engine_version
  instance_class                  = var.database_instance_class
  allocated_storage               = 20
  max_allocated_storage           = 100
  storage_type                    = "gp3"
  storage_encrypted               = true
  db_name                         = "arvana_wear"
  username                        = "arvana_admin"
  password                        = random_password.database_admin.result
  port                            = 5432
  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.database.id]
  publicly_accessible             = false
  multi_az                        = var.database_multi_az
  backup_retention_period         = var.database_backup_retention_period
  auto_minor_version_upgrade      = true
  deletion_protection             = var.database_deletion_protection
  skip_final_snapshot             = var.database_skip_final_snapshot
  final_snapshot_identifier       = var.database_skip_final_snapshot ? null : "${local.name}-final"
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  apply_immediately               = false
  copy_tags_to_snapshot           = true
  tags                            = { Name = "${local.name}-postgres" }

  depends_on = [aws_cloudwatch_log_group.rds]
}

resource "aws_cloudwatch_metric_alarm" "database_cpu" {
  alarm_name          = "${local.name}-database-cpu-high"
  alarm_description   = "RDS average CPU has stayed above 80% for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }
}

resource "aws_cloudwatch_metric_alarm" "database_storage" {
  alarm_name          = "${local.name}-database-storage-low"
  alarm_description   = "RDS free storage has fallen below 2 GiB."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 2147483648
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }
}

resource "aws_secretsmanager_secret" "application" {
  name                    = "arvana/${var.environment}/application"
  description             = "Runtime configuration for Arvana Wear ${var.environment}"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "application" {
  secret_id = aws_secretsmanager_secret.application.id
  secret_string = jsonencode({
    NODE_ENV    = "production"
    DB_HOST     = aws_db_instance.main.address
    DB_PORT     = "5432"
    DB_NAME     = aws_db_instance.main.db_name
    DB_USER     = "arvana_app"
    DB_PASSWORD = random_password.database_app.result
    DB_SSL      = "verify-full"
    DB_SSL_CA   = "/etc/ssl/certs/ca-certificates.crt"
    DB_POOL_MAX = tostring(var.database_pool_max)
    JWT_SECRET  = random_password.jwt.result
    CORS_ORIGIN = var.application_origin
  })
}

resource "aws_secretsmanager_secret" "database_admin" {
  name                    = "arvana/${var.environment}/database-admin"
  description             = "Restricted migration credentials for Arvana Wear ${var.environment}"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "database_admin" {
  secret_id = aws_secretsmanager_secret.database_admin.id
  secret_string = jsonencode({
    DB_ADMIN_USER     = aws_db_instance.main.username
    DB_ADMIN_PASSWORD = random_password.database_admin.result
  })
}

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "external_secrets_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${local.name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_assume.json
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "read-arvana-application-secret"
  role = aws_iam_role.external_secrets.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          aws_secretsmanager_secret.application.arn,
          aws_secretsmanager_secret.database_admin.arn,
        ]
      }
    ]
  })
}

data "aws_iam_policy_document" "cluster_autoscaler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${local.name}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume.json
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "scale-tagged-eks-node-groups"
  role = aws_iam_role.cluster_autoscaler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeLaunchTemplateVersions",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"       = "true"
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${local.name}" = "owned"
          }
        }
      }
    ]
  })
}

data "aws_iam_policy_document" "xray_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:monitoring:otel-collector"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "otel_collector" {
  name               = "${local.name}-otel-xray"
  assume_role_policy = data.aws_iam_policy_document.xray_assume.json
}

resource "aws_iam_role_policy" "otel_xray" {
  name = "write-xray-traces"
  role = aws_iam_role.otel_collector.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets", "xray:GetSamplingStatisticSummaries"]
      Resource = "*"
    }]
  })
}

data "aws_iam_policy_document" "grafana_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:monitoring:kube-prometheus-stack-grafana"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "grafana" {
  name               = "${local.name}-grafana-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.grafana_assume.json
}

resource "aws_iam_role_policy" "grafana_cloudwatch" {
  name = "read-cloudwatch-metrics-and-logs"
  role = aws_iam_role.grafana.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:DescribeAlarms",
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics",
        "ec2:DescribeTags",
        "ec2:DescribeInstances",
        "ec2:DescribeRegions",
        "tag:GetResources",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:GetLogEvents",
        "logs:StartQuery",
        "logs:StopQuery",
        "logs:GetQueryResults",
        "xray:BatchGetTraces",
        "xray:GetServiceGraph",
        "xray:GetTimeSeriesServiceStatistics",
        "xray:GetTraceGraph",
        "xray:GetTraceSummaries",
      ]
      Resource = "*"
    }]
  })
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions" {
  name               = "${local.name}-github-ecr-publisher"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

resource "aws_iam_role_policy" "github_ecr_push" {
  name = "push-arvana-images-to-ecr"
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = [aws_ecr_repository.api.arn, aws_ecr_repository.frontend.arn]
      }
    ]
  })
}

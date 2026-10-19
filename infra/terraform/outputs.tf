output "aws_region" {
  value = var.aws_region
}

output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "api_ecr_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "frontend_ecr_repository_url" {
  value = aws_ecr_repository.frontend.repository_url
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

output "external_secrets_role_arn" {
  value = aws_iam_role.external_secrets.arn
}

output "cluster_autoscaler_role_arn" {
  value = aws_iam_role.cluster_autoscaler.arn
}

output "otel_collector_role_arn" {
  value = aws_iam_role.otel_collector.arn
}

output "grafana_role_arn" {
  value = aws_iam_role.grafana.arn
}

output "application_secret_arn" {
  value = aws_secretsmanager_secret.application.arn
}

output "database_admin_secret_arn" {
  value = aws_secretsmanager_secret.database_admin.arn
}

output "database_endpoint" {
  value = aws_db_instance.main.address
}

output "database_port" {
  value = aws_db_instance.main.port
}

output "database_name" {
  value = aws_db_instance.main.db_name
}

output "vpc_id" {
  value = aws_vpc.main.id
}

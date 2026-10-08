locals {
  cluster = var.role == "primary" ? aws_rds_cluster.primary[0] : aws_rds_cluster.secondary[0]
}

output "cluster_identifier" {
  value = local.cluster.cluster_identifier
}

output "writer_endpoint" {
  description = "Regional writer endpoint. Writable on the primary; becomes writable on the secondary only after promotion."
  value       = local.cluster.endpoint
}

output "reader_endpoint" {
  value = local.cluster.reader_endpoint
}

output "global_cluster_identifier" {
  value = var.global_cluster_identifier
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}

output "database_name" {
  value = var.database_name
}

output "port" {
  value = var.db_port
}

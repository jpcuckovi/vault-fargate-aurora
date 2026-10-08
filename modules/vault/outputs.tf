output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.vault.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.vault.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.vault.name
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

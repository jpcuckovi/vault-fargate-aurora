output "ecr_repository_url" {
  value = aws_ecr_repository.bootstrap.repository_url
}

output "ecr_repository_name" {
  value = aws_ecr_repository.bootstrap.name
}

output "task_definition_family" {
  value = aws_ecs_task_definition.bootstrap.family
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.bootstrap.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.bootstrap.name
}

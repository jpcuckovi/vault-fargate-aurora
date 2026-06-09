output "db_password" {
  description = "Generated Aurora master password (consumed by the aurora module on the primary)."
  value       = random_password.db.result
  sensitive   = true
}

output "db_credentials_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "recovery_secret_arn" {
  value = var.create_recovery_secret ? aws_secretsmanager_secret.recovery[0].arn : ""
}

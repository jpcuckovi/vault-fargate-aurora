output "seal_key_arn" {
  description = "ARN of the Vault auto-unseal key in this region."
  value       = var.role == "primary" ? aws_kms_key.seal[0].arn : aws_kms_replica_key.seal[0].arn
}

output "seal_key_id" {
  description = "Key id of the Vault auto-unseal key. Identical across the MRK primary and its replicas."
  value       = var.role == "primary" ? aws_kms_key.seal[0].key_id : aws_kms_replica_key.seal[0].key_id
}

output "data_key_arn" {
  description = "ARN of the regional data-at-rest key."
  value       = aws_kms_key.data.arn
}

output "data_key_id" {
  value = aws_kms_key.data.key_id
}

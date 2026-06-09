output "vault_fqdn" {
  value = module.dns.vault_fqdn
}

output "vault_addr" {
  value = local.vault_addr
}

output "alb_dns_name" {
  value = module.networking.alb_dns_name
}

output "vpc_id" {
  value = module.networking.vpc_id
}

output "private_subnet_ids" {
  value = module.networking.private_subnet_ids
}

output "vault_security_group_id" {
  value = module.networking.vault_security_group_id
}

output "ecs_cluster_name" {
  value = module.vault.cluster_name
}

output "vault_service_name" {
  value = module.vault.service_name
}

output "seal_key_arn" {
  description = "DR replica seal key ARN (shares key id with the primary MRK)."
  value       = module.kms.seal_key_arn
}

output "aurora_cluster_identifier" {
  value = module.aurora.cluster_identifier
}

output "global_cluster_identifier" {
  value = module.aurora.global_cluster_identifier
}

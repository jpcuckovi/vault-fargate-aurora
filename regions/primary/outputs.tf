# -- Values the DR root consumes (wire these into regions/dr/terraform.tfvars) --
output "seal_key_arn" {
  description = "Pass to the DR root as `primary_seal_key_arn`."
  value       = module.kms.seal_key_arn
}

output "global_cluster_identifier" {
  description = "Pass to the DR root as `global_cluster_identifier`."
  value       = module.aurora.global_cluster_identifier
}

# -- Operational outputs --
output "vault_fqdn" {
  value = module.dns.vault_fqdn
}

output "vault_addr" {
  value = local.vault_addr
}

output "vault_endpoint" {
  description = "Public Vault endpoint. Set VAULT_ADDR to this value."
  value       = var.domain_name != "" ? "https://${var.domain_name}" : "http://${module.networking.alb_dns_name}:8200"
}

output "domain_name" {
  description = "Custom domain the stack was deployed with (empty for HTTP-only). The destroy workflow reads this from state to stay symmetric without the operator re-supplying it."
  value       = var.domain_name
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

output "recovery_secret_arn" {
  value = module.secrets.recovery_secret_arn
}

# -- Bootstrap (consumed by the deploy workflow) --
output "bootstrap_ecr_repository_url" {
  value = module.bootstrap.ecr_repository_url
}

output "bootstrap_task_definition_family" {
  value = module.bootstrap.task_definition_family
}

output "bootstrap_log_group_name" {
  value = module.bootstrap.log_group_name
}

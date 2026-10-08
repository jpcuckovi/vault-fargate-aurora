output "zone_id" {
  value = aws_route53_zone.this.zone_id
}

output "vault_fqdn" {
  description = "Fully qualified hostname clients use to reach Vault."
  value       = aws_route53_record.vault.fqdn
}

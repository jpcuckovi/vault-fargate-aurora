variable "name_prefix" {
  description = "Prefix applied to secret names."
  type        = string
}

variable "master_username" {
  description = "Aurora master username stored in the credentials secret."
  type        = string
  default     = "vault_admin"
}

variable "kms_key_arn" {
  description = "Regional KMS key ARN used to encrypt the secrets."
  type        = string
}

variable "replica_regions" {
  description = "Regions to replicate the secrets into (e.g. the DR region) so the DR cluster can read the same credentials/recovery keys. Replicas use the AWS-managed Secrets Manager key in the target region."
  type        = list(string)
  default     = []
}

variable "create_recovery_secret" {
  description = "Whether to create the Vault recovery-keys secret. true in the primary region (where init runs); false in DR (the cluster is the same logical Vault and shares the primary's recovery keys)."
  type        = bool
  default     = true
}

variable "secret_recovery_window_days" {
  description = <<-EOT
    Secrets Manager recovery window (days) applied to the DB-credentials and
    recovery-keys secrets on delete. 0 purges immediately so destroy/redeploy
    cycles don't hit "secret already scheduled for deletion" name conflicts -
    the scaffold default. Set 7-30 in production to keep an undo window.
  EOT
  type        = number
  default     = 0
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}

variable "name_prefix" {
  description = "Prefix applied to resource names."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "vault_addr" {
  description = "Vault address the bootstrap task hits (the private FQDN, e.g. http://vault.vault.internal:8200)."
  type        = string
}

variable "db_host" {
  description = "Aurora writer endpoint."
  type        = string
}

variable "db_port" {
  description = "Aurora port."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Vault database name."
  type        = string
}

variable "db_username" {
  description = "Aurora master username."
  type        = string
}

variable "db_credentials_secret_arn" {
  description = "Secrets Manager ARN holding {username,password}."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS data key ARN used to encrypt the DB credentials and recovery secrets. The execution role needs kms:Decrypt; the task role needs kms:GenerateDataKey."
  type        = string
}

variable "recovery_secret_arn" {
  description = "Secrets Manager ARN that receives the recovery keys + root token."
  type        = string
}

variable "recovery_shares" {
  description = "Number of recovery key shares."
  type        = number
  default     = 5
}

variable "recovery_threshold" {
  description = "Recovery key threshold."
  type        = number
  default     = 3
}

variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "image_tag" {
  description = "Tag of the bootstrap image in ECR (pushed by the deploy workflow)."
  type        = string
  default     = "latest"
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}

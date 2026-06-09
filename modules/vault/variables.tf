variable "name_prefix" {
  description = "Prefix applied to resource names."
  type        = string
}

variable "region" {
  description = "AWS region this cluster runs in (passed to the awskms seal)."
  type        = string
}

variable "vault_image" {
  description = "Vault container image. OSS 2.0.x; CE 2.0.1 lacks some arch artifacts, so the task pins linux/amd64. Bump to 2.0.2 when released."
  type        = string
  default     = "hashicorp/vault:2.0.1"
}

variable "desired_count" {
  description = "Number of Vault tasks. Use >=3 in the active region; 0 in the warm-DR region until failover."
  type        = number
  default     = 3
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 1024
}

variable "task_memory" {
  description = "Fargate task memory (MiB)."
  type        = number
  default     = 2048
}

variable "private_subnet_ids" {
  description = "Private subnets the tasks run in."
  type        = list(string)
}

variable "vault_security_group_id" {
  description = "Security group for the Vault tasks."
  type        = string
}

variable "target_group_arn" {
  description = "ALB target group the active node registers with."
  type        = string
}

variable "seal_kms_key_id" {
  description = "Multi-region KMS key id for auto-unseal."
  type        = string
}

variable "seal_kms_key_arn" {
  description = "Multi-region KMS key ARN (for the task IAM policy)."
  type        = string
}

variable "db_host" {
  description = "Aurora regional writer endpoint."
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
  description = "Secrets Manager ARN holding {username,password}; the password key is injected into the task."
  type        = string
}

variable "kms_data_key_arn" {
  description = "KMS data key ARN used to encrypt the DB credentials secret. The execution role needs kms:Decrypt to inject DB_PASSWORD into the task."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 30
}

variable "service_connect_namespace_arn" {
  description = "ARN of the ECS Service Connect (Cloud Map HTTP) namespace for inter-node 8201."
  type        = string
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}

variable "name_prefix" {
  description = "Prefix applied to resource names."
  type        = string
}

variable "role" {
  description = "\"primary\" creates the global cluster + writable regional cluster. \"secondary\" joins the existing global cluster as a read-only replica."
  type        = string
  validation {
    condition     = contains(["primary", "secondary"], var.role)
    error_message = "role must be \"primary\" or \"secondary\"."
  }
}

variable "global_cluster_identifier" {
  description = "Name of the Aurora global cluster. The primary creates it; the secondary references it by name."
  type        = string
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version (must support Global Database and write forwarding)."
  type        = string
  default     = "16.6"
}

variable "database_name" {
  description = "Initial database name Vault stores its data in (primary only; replicated to secondary)."
  type        = string
  default     = "vault"
}

variable "master_username" {
  description = "Master username (primary only)."
  type        = string
  default     = "vault_admin"
}

variable "master_password" {
  description = "Master password (primary only). Sourced from the secrets module."
  type        = string
  default     = ""
  sensitive   = true
}

variable "instance_class" {
  description = "Aurora instance class (Global Database requires r5/r6 large or bigger)."
  type        = string
  default     = "db.r6g.large"
}

variable "instance_count" {
  description = "Number of Aurora instances in this region's cluster."
  type        = number
  default     = 2
}

variable "subnet_ids" {
  description = "Private subnet ids for the DB subnet group."
  type        = list(string)
}

variable "vault_security_group_id" {
  description = "Security group of the Vault tasks (allowed to reach Postgres on 5432)."
  type        = string
}

variable "vpc_id" {
  description = "VPC id (for the DB security group)."
  type        = string
}

variable "kms_key_arn" {
  description = "Regional KMS key ARN for storage encryption."
  type        = string
}

variable "db_port" {
  description = "Postgres port."
  type        = number
  default     = 5432
}

variable "deletion_protection" {
  description = "Enable deletion protection. Keep false to allow the destroy workflow; set true in production."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on destroy. true for development; false in production."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}

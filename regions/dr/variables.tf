variable "region" {
  description = "DR AWS region (Region 2)."
  type        = string
}

variable "name_prefix" {
  type    = string
  default = "vault-dr"
}

# ---- Cross-region inputs (from the primary root's outputs) ----
variable "primary_seal_key_arn" {
  description = "ARN of the primary multi-region seal key. From primary output `seal_key_arn`."
  type        = string
}

variable "global_cluster_identifier" {
  description = "Aurora global cluster name created by the primary. From primary output `global_cluster_identifier`."
  type        = string
}

variable "db_credentials_secret_name" {
  description = "Name of the primary's Aurora credentials secret, replicated into this region. The DR Vault must use the same credentials as the primary because the Aurora secondary inherits them from the global cluster. Defaults to the primary name_prefix convention."
  type        = string
  default     = "vault-primary/aurora/master"
}

# ---- Networking ----
variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = []
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.0.0/24", "10.20.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.10.0/24", "10.20.11.0/24"]
}

variable "client_ingress_cidrs" {
  type    = list(string)
  default = ["10.20.0.0/16"]
}

variable "zone_name" {
  type    = string
  default = "vault.internal"
}

variable "vault_hostname" {
  type    = string
  default = "vault.vault.internal"
}

variable "master_username" {
  type    = string
  default = "vault_admin"
}

variable "vault_image" {
  type    = string
  default = "hashicorp/vault:2.0.1"
}

variable "vault_desired_count" {
  description = "Warm DR: 0 until failover. Set >0 (and promote Aurora) during a regional failover."
  type        = number
  default     = 0
}

variable "aurora_engine_version" {
  type    = string
  default = "16.6"
}

variable "aurora_instance_class" {
  type    = string
  default = "db.r6g.large"
}

variable "aurora_instance_count" {
  type    = number
  default = 2
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "tags" {
  type = map(string)
  default = {
    Project = "vault-ha"
    Region  = "dr"
  }
}

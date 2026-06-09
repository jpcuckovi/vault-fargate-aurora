variable "region" {
  description = "Primary AWS region (Region 1)."
  type        = string
}

variable "name_prefix" {
  description = "Resource name prefix for the primary region."
  type        = string
  default     = "vault-primary"
}

variable "global_cluster_identifier" {
  description = "Aurora global cluster name. The primary creates it; pass the same value to the DR root."
  type        = string
  default     = "vault-global"
}

variable "dr_region" {
  description = "DR region (Region 2). The DB credentials + recovery secrets are replicated here so the DR cluster can read them."
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = []
  # If empty, the root selects the first two AZs in the region automatically.
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.10.0.0/24", "10.10.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.10.10.0/24", "10.10.11.0/24"]
}

variable "client_ingress_cidrs" {
  description = "CIDRs allowed to reach the Vault ALB. Defaults to open (internet-facing); restrict for production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "domain_name" {
  description = "Optional FQDN for the Vault endpoint (e.g. vault.example.com). When set, an ACM certificate is created and an HTTPS:443 listener is added to the ALB. The domain's Route53 public hosted zone must exist in this account. Leave empty for HTTP-only on port 8200."
  type        = string
  default     = ""
}

variable "zone_name" {
  description = "Private hosted zone name."
  type        = string
  default     = "vault.internal"
}

variable "vault_hostname" {
  description = "Hostname record for Vault inside the private zone."
  type        = string
  default     = "vault.vault.internal"
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
  description = "Active-region Vault task count."
  type        = number
  default     = 3
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
    Region  = "primary"
  }
}

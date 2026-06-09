variable "name_prefix" {
  description = "Prefix applied to resource names."
  type        = string
}

variable "zone_name" {
  description = "Private hosted zone name (e.g. \"vault.internal\")."
  type        = string
}

variable "record_name" {
  description = "Hostname clients use to reach Vault (e.g. \"vault.vault.internal\")."
  type        = string
}

variable "vpc_id" {
  description = "VPC to associate the private hosted zone with."
  type        = string
}

variable "alb_dns_name" {
  description = "ALB DNS name (alias target)."
  type        = string
}

variable "alb_zone_id" {
  description = "ALB hosted zone id (alias target)."
  type        = string
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}

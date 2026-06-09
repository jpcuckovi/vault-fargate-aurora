variable "name_prefix" {
  description = "Prefix applied to all resource names (e.g. \"vault-primary\")."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "azs" {
  description = "Availability zones to spread subnets across (provide at least 2)."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per AZ). Used only when the ALB is internet-facing and for NAT gateways."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets (one per AZ). ECS tasks and Aurora live here."
  type        = list(string)
}

variable "alb_internal" {
  description = "If true the ALB is internal (private). Set true for the DR region; primary defaults to internet-facing."
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "ACM certificate ARN. When set, adds an HTTPS:443 listener and redirects HTTP:80 to HTTPS. Leave empty for HTTP-only on port 8200."
  type        = string
  default     = ""
}

variable "client_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the Vault ALB on 8200."
  type        = list(string)
}

variable "vault_api_port" {
  description = "Vault API / client port."
  type        = number
  default     = 8200
}

variable "vault_cluster_port" {
  description = "Vault cluster / request-forwarding port (inter-node)."
  type        = number
  default     = 8201
}

variable "health_check_path" {
  description = <<-EOT
    ALB target-group health check path. The query parameters make Vault's
    /v1/sys/health return 200 for every alive node (active, standby, perf
    standby, uninitialized, sealed, DR secondary). This target group also governs
    ECS task lifecycle, so a bare path deadlocks bootstrap and kills standby
    tasks; keep the parameters.
  EOT
  type        = string
  default     = "/v1/sys/health?standbyok=true&perfstandbyok=true&uninitcode=200&sealedcode=200&drsecondarycode=200"
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}

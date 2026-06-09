data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs        = length(var.azs) > 0 ? var.azs : slice(data.aws_availability_zones.available.names, 0, 2)
  vault_addr = "http://${var.vault_hostname}:8200"

  # Parent zone: "vault.example.com" -> "example.com"
  domain_parts = var.domain_name != "" ? split(".", var.domain_name) : []
  parent_zone  = length(local.domain_parts) > 1 ? join(".", slice(local.domain_parts, 1, length(local.domain_parts))) : ""
}

data "aws_route53_zone" "public" {
  count        = var.domain_name != "" ? 1 : 0
  name         = local.parent_zone
  private_zone = false
}

resource "aws_acm_certificate" "vault" {
  count             = var.domain_name != "" ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"
  tags              = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.domain_name != "" ? {
    for dvo in aws_acm_certificate.vault[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.public[0].zone_id
}

resource "aws_acm_certificate_validation" "vault" {
  count                   = var.domain_name != "" ? 1 : 0
  certificate_arn         = aws_acm_certificate.vault[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_route53_record" "vault_public" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = module.networking.alb_dns_name
    zone_id                = module.networking.alb_zone_id
    evaluate_target_health = true
  }
}

module "networking" {
  source = "../../modules/networking"

  name_prefix          = var.name_prefix
  vpc_cidr             = var.vpc_cidr
  azs                  = local.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  client_ingress_cidrs = var.client_ingress_cidrs
  alb_internal         = false
  certificate_arn      = var.domain_name != "" ? aws_acm_certificate_validation.vault[0].certificate_arn : ""
  tags                 = var.tags
}

module "kms" {
  source = "../../modules/kms"

  name_prefix = var.name_prefix
  role        = "primary"
  tags        = var.tags
}

module "secrets" {
  source = "../../modules/secrets"

  name_prefix            = var.name_prefix
  master_username        = var.master_username
  kms_key_arn            = module.kms.data_key_arn
  create_recovery_secret = true
  replica_regions        = [var.dr_region]
  tags                   = var.tags
}

module "aurora" {
  source = "../../modules/aurora"

  name_prefix               = var.name_prefix
  role                      = "primary"
  global_cluster_identifier = var.global_cluster_identifier
  engine_version            = var.aurora_engine_version
  database_name             = "vault"
  master_username           = var.master_username
  master_password           = module.secrets.db_password
  instance_class            = var.aurora_instance_class
  instance_count            = var.aurora_instance_count
  subnet_ids                = module.networking.private_subnet_ids
  vault_security_group_id   = module.networking.vault_security_group_id
  vpc_id                    = module.networking.vpc_id
  kms_key_arn               = module.kms.data_key_arn
  deletion_protection       = var.deletion_protection
  tags                      = var.tags
}

resource "aws_service_discovery_http_namespace" "this" {
  name        = var.name_prefix
  description = "Service Connect namespace for Vault inter-node traffic"
  tags        = var.tags
}

module "vault" {
  source = "../../modules/vault"

  name_prefix                   = var.name_prefix
  region                        = var.region
  vault_image                   = var.vault_image
  desired_count                 = var.vault_desired_count
  private_subnet_ids            = module.networking.private_subnet_ids
  vault_security_group_id       = module.networking.vault_security_group_id
  target_group_arn              = module.networking.target_group_arn
  seal_kms_key_id               = module.kms.seal_key_id
  seal_kms_key_arn              = module.kms.seal_key_arn
  db_host                       = module.aurora.writer_endpoint
  db_name                       = module.aurora.database_name
  db_username                   = var.master_username
  db_credentials_secret_arn     = module.secrets.db_credentials_secret_arn
  kms_data_key_arn              = module.kms.data_key_arn
  service_connect_namespace_arn = aws_service_discovery_http_namespace.this.arn
  tags                          = var.tags
}

module "dns" {
  source = "../../modules/dns"

  name_prefix  = var.name_prefix
  zone_name    = var.zone_name
  record_name  = var.vault_hostname
  vpc_id       = module.networking.vpc_id
  alb_dns_name = module.networking.alb_dns_name
  alb_zone_id  = module.networking.alb_zone_id
  tags         = var.tags
}

module "bootstrap" {
  source = "../../modules/bootstrap"

  name_prefix               = var.name_prefix
  region                    = var.region
  vault_addr                = local.vault_addr
  db_host                   = module.aurora.writer_endpoint
  db_name                   = module.aurora.database_name
  db_username               = var.master_username
  db_credentials_secret_arn = module.secrets.db_credentials_secret_arn
  recovery_secret_arn       = module.secrets.recovery_secret_arn
  kms_key_arn               = module.kms.data_key_arn
  tags                      = var.tags
}

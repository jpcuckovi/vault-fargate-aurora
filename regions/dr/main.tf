data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs        = length(var.azs) > 0 ? var.azs : slice(data.aws_availability_zones.available.names, 0, 2)
  vault_addr = "http://${var.vault_hostname}:8200"
}

# The Aurora secondary inherits the global cluster's master credentials, so the
# DR Vault must use the SAME password as the primary. The replicated credentials
# secret (created by the primary root, replicated into this region) is read here.
data "aws_secretsmanager_secret" "db" {
  name = var.db_credentials_secret_name
}

module "networking" {
  source = "../../modules/networking"

  name_prefix          = var.name_prefix
  vpc_cidr             = var.vpc_cidr
  azs                  = local.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  client_ingress_cidrs = var.client_ingress_cidrs
  alb_internal         = true
  tags                 = var.tags
}

module "kms" {
  source = "../../modules/kms"

  name_prefix          = var.name_prefix
  role                 = "dr"
  primary_seal_key_arn = var.primary_seal_key_arn
  tags                 = var.tags
}

module "aurora" {
  source = "../../modules/aurora"

  name_prefix               = var.name_prefix
  role                      = "secondary"
  global_cluster_identifier = var.global_cluster_identifier
  engine_version            = var.aurora_engine_version
  database_name             = "vault"
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
  desired_count                 = var.vault_desired_count # 0 until failover
  private_subnet_ids            = module.networking.private_subnet_ids
  vault_security_group_id       = module.networking.vault_security_group_id
  target_group_arn              = module.networking.target_group_arn
  seal_kms_key_id               = module.kms.seal_key_id
  seal_kms_key_arn              = module.kms.seal_key_arn
  db_host                       = module.aurora.writer_endpoint
  db_name                       = module.aurora.database_name
  db_username                   = var.master_username
  db_credentials_secret_arn     = data.aws_secretsmanager_secret.db.arn
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

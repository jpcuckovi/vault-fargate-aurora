locals {
  is_primary = var.role == "primary"
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-aurora"
  subnet_ids = var.subnet_ids
  tags       = merge(var.tags, { Name = "${var.name_prefix}-aurora" })
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-aurora"
  description = "Aurora PostgreSQL - Vault storage backend"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-aurora" })
}

resource "aws_security_group_rule" "db_ingress_vault" {
  type                     = "ingress"
  security_group_id        = aws_security_group.db.id
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  source_security_group_id = var.vault_security_group_id
  description              = "Postgres from Vault tasks"
}

# ---------------------------------------------------------------------------
# Global cluster (created once, by the primary region)
# ---------------------------------------------------------------------------
resource "aws_rds_global_cluster" "this" {
  count                     = local.is_primary ? 1 : 0
  global_cluster_identifier = var.global_cluster_identifier
  engine                    = "aurora-postgresql"
  engine_version            = var.engine_version
  database_name             = var.database_name
  storage_encrypted         = true
  deletion_protection       = var.deletion_protection
}

# ---------------------------------------------------------------------------
# Primary regional cluster (writable)
# ---------------------------------------------------------------------------
resource "aws_rds_cluster" "primary" {
  count                     = local.is_primary ? 1 : 0
  cluster_identifier        = "${var.name_prefix}-aurora"
  engine                    = "aurora-postgresql"
  engine_version            = var.engine_version
  global_cluster_identifier = aws_rds_global_cluster.this[0].id
  database_name             = var.database_name
  master_username           = var.master_username
  master_password           = var.master_password
  db_subnet_group_name      = aws_db_subnet_group.this.name
  vpc_security_group_ids    = [aws_security_group.db.id]
  port                      = var.db_port
  storage_encrypted         = true
  kms_key_id                = var.kms_key_arn
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-aurora-final"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = merge(var.tags, { Name = "${var.name_prefix}-aurora" })

  lifecycle {
    ignore_changes = [replication_source_identifier]
  }
}

# ---------------------------------------------------------------------------
# Secondary regional cluster (read-only replica in the DR region)
# ---------------------------------------------------------------------------
resource "aws_rds_cluster" "secondary" {
  count                     = local.is_primary ? 0 : 1
  cluster_identifier        = "${var.name_prefix}-aurora"
  engine                    = "aurora-postgresql"
  engine_version            = var.engine_version
  global_cluster_identifier = var.global_cluster_identifier
  db_subnet_group_name      = aws_db_subnet_group.this.name
  vpc_security_group_ids    = [aws_security_group.db.id]
  port                      = var.db_port
  storage_encrypted         = true
  kms_key_id                = var.kms_key_arn
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-aurora-final"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = merge(var.tags, { Name = "${var.name_prefix}-aurora" })

  # The secondary inherits credentials from the global cluster and is joined by
  # identifier; ignore_changes keeps Terraform from reverting the replication
  # wiring AWS manages.
  lifecycle {
    ignore_changes = [
      replication_source_identifier,
      global_cluster_identifier,
      master_username,
      master_password,
    ]
  }
}

# ---------------------------------------------------------------------------
# Cluster instances (both roles)
# ---------------------------------------------------------------------------
resource "aws_rds_cluster_instance" "this" {
  count                = var.instance_count
  identifier           = "${var.name_prefix}-aurora-${count.index}"
  cluster_identifier   = local.is_primary ? aws_rds_cluster.primary[0].id : aws_rds_cluster.secondary[0].id
  engine               = "aurora-postgresql"
  engine_version       = var.engine_version
  instance_class       = var.instance_class
  db_subnet_group_name = aws_db_subnet_group.this.name
  tags                 = merge(var.tags, { Name = "${var.name_prefix}-aurora-${count.index}" })
}

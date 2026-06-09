resource "random_password" "db" {
  length  = 32
  special = false # avoid URL-encoding headaches in the postgres connection string
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.name_prefix}/aurora/master"
  description             = "Aurora master credentials for the Vault storage backend"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-aurora-master" })

  dynamic "replica" {
    for_each = toset(var.replica_regions)
    content {
      region = replica.value
    }
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.db.result
  })
}

# ---------------------------------------------------------------------------
# Vault recovery keys (auto-unseal => recovery keys, not unseal keys).
# Created empty; the bootstrap task writes the real value after
# `vault operator init`. ignore_changes keeps Terraform from clobbering it.
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "recovery" {
  count                   = var.create_recovery_secret ? 1 : 0
  name                    = "${var.name_prefix}/vault/recovery"
  description             = "Vault recovery keys + initial root token (populated by bootstrap)"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-vault-recovery" })

  dynamic "replica" {
    for_each = toset(var.replica_regions)
    content {
      region = replica.value
    }
  }
}

resource "aws_secretsmanager_secret_version" "recovery_placeholder" {
  count         = var.create_recovery_secret ? 1 : 0
  secret_id     = aws_secretsmanager_secret.recovery[0].id
  secret_string = jsonencode({ status = "uninitialized" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

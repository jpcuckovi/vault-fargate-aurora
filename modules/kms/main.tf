locals {
  is_primary = var.role == "primary"
}

# ---------------------------------------------------------------------------
# Vault auto-unseal (seal) key.
#
# This is a MULTI-REGION key. The primary region creates the MRK primary; the
# DR region creates a replica that shares the same key id + key material, so the
# DR Vault cluster can decrypt the root key that the primary cluster sealed and
# wrote into the (replicated) Aurora storage. A *separate* key per region would
# make the DR cluster unable to unseal the shared data set.
# ---------------------------------------------------------------------------
resource "aws_kms_key" "seal" {
  count                   = local.is_primary ? 1 : 0
  description             = "${var.name_prefix} Vault auto-unseal (multi-region primary)"
  multi_region            = true
  deletion_window_in_days = var.deletion_window_days
  enable_key_rotation     = true
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-seal" })
}

resource "aws_kms_replica_key" "seal" {
  count                   = local.is_primary ? 0 : 1
  description             = "${var.name_prefix} Vault auto-unseal (multi-region replica)"
  primary_key_arn         = var.primary_seal_key_arn
  deletion_window_in_days = var.deletion_window_days
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-seal" })
}

resource "aws_kms_alias" "seal" {
  name          = "alias/${var.name_prefix}-vault-seal"
  target_key_id = local.is_primary ? aws_kms_key.seal[0].key_id : aws_kms_replica_key.seal[0].key_id
}

# ---------------------------------------------------------------------------
# Regional data key - used for Aurora storage encryption, Secrets Manager and
# CloudWatch log encryption. Single-region; each region encrypts its own data
# at rest with its own key (the Aurora secondary is encrypted with the DR key).
# ---------------------------------------------------------------------------
resource "aws_kms_key" "data" {
  description             = "${var.name_prefix} Vault data-at-rest (regional)"
  deletion_window_in_days = var.deletion_window_days
  enable_key_rotation     = true
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-data" })
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.name_prefix}-vault-data"
  target_key_id = aws_kms_key.data.key_id
}

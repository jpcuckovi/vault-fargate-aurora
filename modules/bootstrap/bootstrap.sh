#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot Vault bootstrap, run as an in-VPC Fargate task (the ALB is private,
# so this cannot run from a GitHub-hosted runner).
#
#   1. Create the Postgres storage schema (Vault never creates its own tables).
#   2. Wait for the Vault service to become reachable + report uninitialized.
#   3. Run `operator init` with auto-unseal (=> recovery keys, not unseal keys).
#   4. Store recovery keys + initial root token in Secrets Manager.
#
# Idempotent: re-running after a successful init is a no-op.
# ---------------------------------------------------------------------------
set -euo pipefail

: "${AWS_REGION:?}"
: "${VAULT_ADDR:?}"            # e.g. http://vault.vault.internal:8200
: "${DB_HOST:?}"
: "${DB_PORT:=5432}"
: "${DB_NAME:?}"
: "${DB_USERNAME:?}"
: "${DB_PASSWORD:?}"          # injected from Secrets Manager
: "${RECOVERY_SECRET_ID:?}"
: "${RECOVERY_SHARES:=5}"
: "${RECOVERY_THRESHOLD:=3}"

echo "==> [1/4] Creating Vault Postgres schema (idempotent)"
export PGPASSWORD="${DB_PASSWORD}"
psql "host=${DB_HOST} port=${DB_PORT} dbname=${DB_NAME} user=${DB_USERNAME} sslmode=require" \
  -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS vault_kv_store (
  parent_path TEXT COLLATE "C" NOT NULL,
  path        TEXT COLLATE "C",
  key         TEXT COLLATE "C",
  value       BYTEA,
  CONSTRAINT pkey PRIMARY KEY (path, key)
);

CREATE INDEX IF NOT EXISTS parent_path_idx ON vault_kv_store (parent_path);

CREATE TABLE IF NOT EXISTS vault_ha_locks (
  ha_key      TEXT COLLATE "C" NOT NULL,
  ha_identity TEXT COLLATE "C" NOT NULL,
  ha_value    TEXT COLLATE "C",
  valid_until TIMESTAMP WITH TIME ZONE NOT NULL,
  CONSTRAINT ha_key PRIMARY KEY (ha_key)
);
SQL

echo "==> [2/4] Waiting for Vault to respond (it crash-loops until the schema exists, then comes up sealed/uninitialized)"
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null --max-time 5 "${VAULT_ADDR}/v1/sys/seal-status"; then
    echo "    Vault reachable."
    break
  fi
  echo "    attempt ${i}: not reachable yet, sleeping 10s"
  sleep 10
done

INITIALIZED="$(curl -fsS --max-time 5 "${VAULT_ADDR}/v1/sys/init" | jq -r '.initialized')"
if [ "${INITIALIZED}" = "true" ]; then
  echo "==> Vault already initialized - nothing to do."
  exit 0
fi

echo "==> [3/4] Initializing Vault (recovery_shares=${RECOVERY_SHARES} recovery_threshold=${RECOVERY_THRESHOLD})"
INIT_RESPONSE="$(curl -fsS --max-time 30 -X PUT \
  -d "{\"recovery_shares\":${RECOVERY_SHARES},\"recovery_threshold\":${RECOVERY_THRESHOLD}}" \
  "${VAULT_ADDR}/v1/sys/init")"

if ! echo "${INIT_RESPONSE}" | jq -e '.root_token' >/dev/null 2>&1; then
  echo "FATAL: init response did not contain a root token:" >&2
  echo "${INIT_RESPONSE}" >&2
  exit 1
fi

echo "==> [4/4] Storing recovery keys + root token in Secrets Manager (${RECOVERY_SECRET_ID})"
aws secretsmanager put-secret-value \
  --region "${AWS_REGION}" \
  --secret-id "${RECOVERY_SECRET_ID}" \
  --secret-string "${INIT_RESPONSE}" >/dev/null

echo "==> Bootstrap complete."
echo "    SECURITY: revoke the initial root token after configuring auth backends:"
echo "      vault token revoke <root_token>"

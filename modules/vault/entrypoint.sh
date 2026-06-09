#!/bin/sh
# ---------------------------------------------------------------------------
# Vault entrypoint for ECS Fargate.
#
# Fargate gives each task its own ENI / private IP, which Vault must advertise
# as api_addr (8200) and cluster_addr (8201) so standby nodes can forward
# requests to the active node. The IP is read from the ECS task metadata
# endpoint, the config is rendered, then the Vault server is exec'd.
#
# The task ENI IP is parsed from the ECS task metadata with grep (no jq): the
# stock hashicorp/vault image has no jq and cannot apk add at runtime as a
# non-root user. For production, bake any needed tooling into a custom image.
# ---------------------------------------------------------------------------
set -eu

if [ -z "${ECS_CONTAINER_METADATA_URI_V4:-}" ]; then
  echo "FATAL: ECS_CONTAINER_METADATA_URI_V4 not set (not running on Fargate?)" >&2
  exit 1
fi

# Pull the first IPv4Addresses entry out of the task metadata JSON. The trailing
# head -1 keeps the pipeline exit status 0 under `set -e` even on no match, so
# the explicit emptiness check below produces the clear diagnostic.
METADATA="$(wget -qO- "${ECS_CONTAINER_METADATA_URI_V4}/task")"
TASK_IP="$(printf '%s' "${METADATA}" \
  | grep -o '"IPv4Addresses":\[[^]]*\]' | head -1 \
  | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | head -1)"

if [ -z "${TASK_IP}" ]; then
  echo "FATAL: could not determine task IP from ECS metadata" >&2
  echo "metadata was: ${METADATA}" >&2
  exit 1
fi

: "${AWS_REGION:?AWS_REGION must be set}"
: "${VAULT_SEAL_KMS_KEY_ID:?VAULT_SEAL_KMS_KEY_ID must be set}"
: "${DB_HOST:?DB_HOST must be set}"
: "${DB_PORT:=5432}"
: "${DB_NAME:?DB_NAME must be set}"
: "${DB_USERNAME:?DB_USERNAME must be set}"
: "${DB_PASSWORD:?DB_PASSWORD must be set (injected from Secrets Manager)}"
: "${DB_SSLMODE:=require}"

# api_addr is plaintext because the ALB terminates client TLS and the listener
# runs with tls_disable. cluster_addr is always https - Vault manages the
# cluster (request-forwarding) TLS internally with self-signed certs.
export VAULT_API_ADDR="http://${TASK_IP}:8200"
export VAULT_CLUSTER_ADDR="https://${TASK_IP}:8201"

CONN_URL="postgres://${DB_USERNAME}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=${DB_SSLMODE}"

cat > /tmp/vault.hcl <<EOF
ui            = true
disable_mlock = true   # Fargate cannot grant IPC_LOCK; ensure no swap

storage "postgresql" {
  connection_url = "${CONN_URL}"
  ha_enabled     = "true"
  table          = "vault_kv_store"
  ha_table       = "vault_ha_locks"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

seal "awskms" {
  region     = "${AWS_REGION}"
  kms_key_id = "${VAULT_SEAL_KMS_KEY_ID}"
}
EOF

# The vault 2.0.x binary ships with the cap_ipc_lock file capability and the
# image runs as the non-root vault user. Fargate's capability bounding set
# excludes IPC_LOCK, so exec'ing a binary whose effective capability bit is set
# fails with EPERM ("Operation not permitted"). With disable_mlock the
# capability is unnecessary, so it is stripped from the binary before exec. Stripping
# needs CAP_SETFCAP, so the task definition runs this as root (user = "0").
VAULT_BIN="$(readlink -f "$(command -v vault)")"
setcap -r "${VAULT_BIN}" 2>/dev/null || true

echo "Starting Vault: api_addr=${VAULT_API_ADDR} cluster_addr=${VAULT_CLUSTER_ADDR}"
exec vault server -config=/tmp/vault.hcl

# Copilot instructions for `vault-ha-aws`

HashiCorp Vault OSS (2.0.x) deployed highly-available on AWS: **ECS Fargate** compute,
**Aurora PostgreSQL Global Database** as the HA storage backend, **AWS KMS multi-region key**
auto-unseal, and a **warm DR region**. All infrastructure is Terraform.

Authoritative docs — read before proposing changes: [`README.md`](../README.md),
[`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md), [`docs/OPERATIONS.md`](../docs/OPERATIONS.md).
For deploy/bootstrap/failover/teardown procedures, see
[`.github/prompt/vault-ha.prompt.md`](prompt/vault-ha.prompt.md).

## Architectural invariants — never violate these

This is **Model #1: one active Vault cluster + one warm DR region**, the only correct topology
for OSS Vault on a shared, replicated storage backend.

- **One active cluster only.** Primary runs `vault_desired_count = 3`; DR runs `0` until
  failover. An active DR Vault writing through the read-only Aurora replica breaks the
  `vault_ha_locks` consistency Vault depends on (split brain). Never make both regions active.
- **One multi-region KMS key, not one-per-region.** Auto-unseal stores the encrypted root key
  *inside* the storage backend, which Aurora replicates to Region 2. DR uses a KMS **replica**
  key (same key id + material) so it can decrypt the replicated data. Never introduce a
  separate per-region key.
- **Order is fixed.** Deploy primary → bootstrap → DR. Destroy DR → primary. DR consumes the
  primary's `seal_key_arn`, `global_cluster_identifier`, and replicated secrets.

If a request contradicts these (e.g. "make both regions active", "give DR its own KMS key"),
stop and explain: it requires Vault Enterprise replication (Model #2), which this repo does
**not** implement.

## Layout & where things go

```
modules/{networking,kms,aurora,secrets,vault,dns,bootstrap}   reusable building blocks
regions/primary   Region 1 root (active) — creates the global cluster, owns bootstrap
regions/dr        Region 2 root (warm DR) — joins the global cluster, Vault at 0
```

- **Module-internal logic** → edit under `modules/<name>/`.
- **Topology / wiring** (which modules connect, cross-region inputs) → the `regions/*/main.tf`
  roots.
- Each region root is a standalone Terraform working directory with its own `backend.tf`
  (S3 + DynamoDB lock, supplied at `init` time) and `terraform.tfvars.example`.

## Conventions

- Terraform style: run `terraform fmt` on edited files; keep variables in `variables.tf` with a
  `description`, outputs in `outputs.tf`. Mirror the existing aligned-assignment formatting.
- Resource names derive from `name_prefix` (`vault-primary` / `vault-dr`) — keep that pattern;
  don't hardcode names. Secret paths follow `<name_prefix>/...` (e.g. `vault-primary/vault/recovery`,
  `vault-primary/aurora/master`).
- The DR root must reference the primary's replicated DB credentials secret and use the **same**
  master password — the Aurora secondary inherits credentials from the global cluster.
- Cross-region values flow primary-outputs → DR-vars; don't duplicate them as literals.
- Update the example tfvars and the docs/prompt file when you add or change a variable.

## Validation expectations

This stack has been deployed end-to-end in a development account, but it is **not security
hardened** and has not been run at production scale. After edits, run `terraform fmt -check` and,
where the provider registry is reachable, `terraform validate` in the affected region root. Don't
claim something is `plan`/`apply`-verified unless it actually was.

## Production-hardening backlog (don't regress, prefer to improve)

The scaffold trades safety for first-deploy simplicity. Flag or fix when touching related code:
plaintext ALB-terminated TLS (`tls_disable`), `disable_mlock = true`, recovery keys + root token
in Secrets Manager, `deletion_protection = false` / `skip_final_snapshot = true`,
`sslmode=require` (not `verify-full`), the Vault task running as root to strip the `cap_ipc_lock`
capability the `vault:2.0.x` binary carries (Fargate can't grant it), and the
`hashicorp/vault:2.0.1` `linux/amd64` pin.

## CI

Workflows in `.github/workflows/`: `validate.yml` (fmt + validate on PRs, no AWS creds),
`deploy.yml` (apply primary → build/push bootstrap → run bootstrap → apply DR), `destroy.yml`
(DR → primary, guarded by `confirm=destroy`), `failover.yml` (promote Aurora secondary → scale up
DR Vault). All authenticate to AWS with **OIDC** — no stored secrets — by assuming the role from
`cloudformation/github-oidc.yaml` (applied once in the console). Config lives in repo **variables**:
`AWS_DEPLOY_ROLE_ARN`, `PRIMARY_REGION`, `DR_REGION`, `TF_STATE_BUCKET`, `TF_LOCK_TABLE`,
`TF_STATE_BUCKET_REGION`. The deploy workflow creates the state bucket + lock table itself before
`init`. Preserve the deploy/destroy ordering if you edit these.

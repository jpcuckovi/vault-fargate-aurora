---
mode: agent
description: How to operate the vault-ha-aws Terraform — deploy, bootstrap, fail over, and tear down HashiCorp Vault HA on AWS (Fargate + Aurora Global Database).
---

# Operating `vault-ha-aws`

You are working in the `vault-ha-aws` repository: HashiCorp Vault OSS (2.0.x) deployed
highly-available on **ECS Fargate**, with **Aurora PostgreSQL Global Database** as the HA
storage backend, **AWS KMS multi-region key** auto-unseal, and a **warm DR region**.

Read [`README.md`](../../README.md), [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md),
and [`docs/OPERATIONS.md`](../../docs/OPERATIONS.md) before making changes. This prompt
summarizes how to *use* the repo; those docs are the source of truth for *why*.

## The one rule that governs everything

This is **Model #1: a single active Vault cluster + a warm DR region** — the only correct
topology for OSS Vault on a shared, replicated storage backend.

- **One active cluster only.** Region 1 (primary) runs `vault_desired_count = 3`. Region 2
  (DR) runs `vault_desired_count = 0` until failover. Never run both active — an active DR
  Vault writing through the read-only Aurora replica would break the `vault_ha_locks`
  consistency Vault depends on (split brain).
- **One multi-region KMS key, not one-per-region.** Auto-unseal stores the encrypted root
  key *inside* the storage backend, which Aurora replicates to Region 2. The DR region uses
  a KMS **replica** key (same key id + material) so it can decrypt the replicated data. Do
  not introduce a separate per-region key.
- **Order matters.** Deploy primary → bootstrap → DR. Destroy DR → primary. DR consumes the
  primary's seal-key ARN, global cluster id, and replicated secrets.

If a request contradicts these (e.g. "make both regions active", "give DR its own KMS key"),
stop and explain the constraint — it requires Vault Enterprise replication (Model #2), which
this repo does not implement.

## Repo layout

```
modules/
  networking/  VPC, subnets, NAT, SGs, internal ALB + target group + listener
  kms/         multi-region seal key (primary | replica) + regional data key
  aurora/      Aurora global cluster (primary) / secondary join + instances
  secrets/     generated DB credentials + recovery-keys secret + cross-region replication
  vault/       ECS cluster, task def, service, Service Connect, IAM, entrypoint.sh
  dns/         Route53 private hosted zone + ALB alias
  bootstrap/   in-VPC one-shot: Postgres schema + `vault operator init` (Dockerfile + task)
regions/
  primary/     Region 1 root (active) — creates the global cluster, owns bootstrap
  dr/          Region 2 root (warm DR) — joins the global cluster, Vault at 0
```

Each region root is a standalone Terraform working directory with its own
`backend.tf` (S3 + DynamoDB lock, supplied at `init` time) and
`terraform.tfvars.example`.

> **Workflows:** `.github/workflows/` holds `validate.yml`, `deploy.yml`, `destroy.yml`, and
> `failover.yml`. They run on GitHub runners and authenticate to AWS with OIDC (no stored
> secrets) via the role from `cloudformation/github-oidc.yaml`. The CLI steps below are the
> manual equivalent of the deploy workflow.

## Prerequisites

- The OIDC trust anchor applied once from `cloudformation/github-oidc.yaml`, and the six repo
  variables set (`AWS_DEPLOY_ROLE_ARN`, `PRIMARY_REGION`, `DR_REGION`, `TF_STATE_BUCKET`,
  `TF_LOCK_TABLE`, `TF_STATE_BUCKET_REGION`). The deploy workflow creates the state bucket + lock
  table itself.
- For the manual CLI path only: `terraform`, `aws` CLI, `docker`, and AWS credentials with
  permissions for VPC, ECS, ECR, RDS, KMS, Secrets Manager, Route53, IAM, ELB, CloudWatch Logs.

## Deploy (manual, primary → bootstrap → DR)

```bash
# 1. PRIMARY
cd regions/primary
cp terraform.tfvars.example terraform.tfvars      # edit region, dr_region, CIDRs, tags
terraform init \
  -backend-config="bucket=<tf-state-bucket>" \
  -backend-config="key=vault-ha/primary/terraform.tfstate" \
  -backend-config="region=<primary-region>" \
  -backend-config="dynamodb_table=<tf-lock-table>"
terraform apply

# 2. BOOTSTRAP (in-VPC one-shot — the ALB is private, so it cannot run from a laptop/runner)
#    Build + push modules/bootstrap to the ECR repo from the primary output, then run it:
terraform output -raw bootstrap_ecr_repository_url
terraform output -raw bootstrap_task_definition_family
#    docker build/push the image to that ECR repo, then:
aws ecs run-task --cluster <primary ecs_cluster_name output> \
  --task-definition <bootstrap_task_definition_family output> \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[<private_subnet_ids>],securityGroups=[<vault_security_group_id>]}"

# 3. DR (consumes primary outputs)
cd ../dr
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config="key=vault-ha/dr/terraform.tfstate" ...   # same bucket/lock table
terraform apply \
  -var primary_seal_key_arn="$(terraform -chdir=../primary output -raw seal_key_arn)" \
  -var global_cluster_identifier="$(terraform -chdir=../primary output -raw global_cluster_identifier)"
```

### What to expect during bootstrap

The Postgres backend requires its tables (`vault_kv_store`, `vault_ha_locks`) to exist before
Vault starts — **Vault never creates them**. Immediately after the first `apply`, the Vault
tasks **crash-loop** until the bootstrap task creates the schema. Then:

1. Tasks come up sealed + uninitialized (`/v1/sys/health` → **501**) but register as healthy
   targets, so the bootstrap task can reach them through the private ALB.
2. Bootstrap runs `operator init` (`recovery_shares=5`, `recovery_threshold=3`).
3. Vault auto-unseals via KMS; the active node serves **200**.
4. The service converges.

After bootstrap, the recovery keys + initial root token are written to Secrets Manager at
`<name_prefix>/vault/recovery` (e.g. `vault-primary/vault/recovery`):

```bash
aws secretsmanager get-secret-value --secret-id vault-primary/vault/recovery \
  --query SecretString --output text | jq .
# configure auth/secret backends, then REVOKE the initial root token:
vault token revoke <root_token>
```

## Health semantics (ALB target group)

The health check path carries query parameters that make `/v1/sys/health` return
200 for every alive node, so standbys, sealed, and uninitialized tasks stay
healthy. Standby nodes forward client requests to the active node over the
cluster port. This target group also governs ECS task lifecycle, so a bare
`matcher = "200"` deadlocks bootstrap (a fresh Vault returns 501) and kills
standby tasks (429).

| Vault state | Default code | Health check |
|------|---------|------------|
| active | 200 | healthy |
| unsealed standby | 429 | healthy (forwards to active) |
| DR / perf standby | 472/473 | healthy |
| not initialized | 501 | healthy (bootstrap can reach Vault) |
| sealed | 503 | healthy |

## Failover (DR promotion)

Promote the DR Aurora cluster, then scale up DR Vault — it auto-unseals against the
already-replicated data + schema using the replica KMS key.

- **switchover** — planned, zero data loss; requires a healthy current primary.
- **failover** — unplanned (Region 1 outage); minimal possible data loss.

Steps: promote the DR Aurora secondary → wait until available → set DR `vault_desired_count > 0`
(the service sets `ignore_changes = [desired_count]`, so scaling is an operational lever) → wait
for the service to stabilize → verify `/v1/sys/health` returns 200 → repoint client traffic to
the DR endpoint. When Region 1 recovers, rebuild it as the *new* secondary before switching back.

## Teardown (DR → primary)

Destroy **DR first, then primary** (reverse of deploy): the DR Aurora cluster is a member of
the primary's global cluster, and the DR seal key is a replica of the primary key.
`deletion_protection` and `skip_final_snapshot` must allow deletion (the scaffold defaults do;
production should not).

```bash
terraform -chdir=regions/dr destroy
terraform -chdir=regions/primary destroy
```

## Key variables (see each region's `terraform.tfvars.example`)

| Variable | Primary | DR | Notes |
|----------|---------|-----|-------|
| `region` / `dr_region` | active region / DR region | DR region | — |
| `name_prefix` | `vault-primary` | `vault-dr` | drives secret + resource names |
| `vault_desired_count` | `3` | `0` | **never run DR active before failover** |
| `global_cluster_identifier` | created here | from primary output | must match |
| `primary_seal_key_arn` | — | from primary `seal_key_arn` output | KMS replica source |
| `db_credentials_secret_name` | — | `vault-primary/aurora/master` | DR reads the replicated secret; **same master password as primary** |
| `vpc_cidr` | `10.10.0.0/16` | `10.20.0.0/16` | keep regions non-overlapping |
| `deletion_protection` | `false` | `false` | set `true` for production |

## Security caveats — flip these before production

This stack has been deployed end-to-end in a development account but is **not security hardened**
and has not been run at production scale. Before relying on it, run `terraform init && validate &&
plan` against a real account and address:

- **ALB-terminated TLS / `tls_disable`** — Vault listens plaintext behind the ALB. Move to
  end-to-end TLS (ACM cert + Vault TLS listener + HTTPS target group).
- **`disable_mlock = true`** — Fargate can't grant `IPC_LOCK`. Ensure no host swap.
- **Recovery keys + root token in Secrets Manager** — co-located with the KMS-holding cloud.
  Consider splitting recovery shares to separate custodians, and always revoke the root token.
- **`deletion_protection = false`, `skip_final_snapshot = true`** — set both to production
  values once teardown convenience is no longer needed.
- **`sslmode=require`** (not `verify-full`) on the Postgres connection — use `verify-full` with
  the RDS CA bundle in production.
- **Vault task runs as root** — the entrypoint strips the `cap_ipc_lock` capability from the
  `vault:2.0.x` binary (Fargate can't grant it; `disable_mlock` makes it unnecessary), which
  needs root. Bake a custom image with the capability removed and run non-root for production.
- **`hashicorp/vault:2.0.1` CE** pins `linux/amd64` (missing artifacts for some arches). Bump
  to `2.0.2` when released.

## When asked to change this repo

- Preserve the single-active-cluster + multi-region-key invariants above.
- Module edits live under `modules/`; wiring/topology lives in the `regions/*/main.tf` roots.
- Validate HCL after edits: `terraform fmt -check` and (where reachable) `terraform validate`
  in the affected region root.
- If you edit the CI workflows, preserve the order: deploy = apply primary → build/push bootstrap
  → run bootstrap → apply DR; destroy = DR → primary. Keep AWS auth on OIDC (no stored secrets).

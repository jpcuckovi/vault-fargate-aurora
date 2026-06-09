# Vault HA on AWS (Fargate + Aurora Global Database)

HashiCorp Vault (OSS, 2.0.x) deployed highly-available on AWS ECS Fargate, using
Aurora PostgreSQL as the HA storage backend, AWS KMS auto-unseal, and a
warm disaster-recovery region.

> **Status:** validated by a successful end-to-end deploy in a development
> account (primary + bootstrap + DR). **It is not security hardened** and has not
> been run at production scale. It carries deliberate dev-only trade-offs
> (plaintext listener, root container, secrets in Secrets Manager, no deletion
> protection — see [security caveats](#security-caveats-read-before-production)).
> Do not deploy to production without addressing every caveat. See
> [Validation](#validation).

## Architecture (Model #1 — single active cluster + warm DR)

```
        Region 1 (PRIMARY, active)                   Region 2 (DR, warm)
  ┌─────────────────────────────────┐         ┌─────────────────────────────────┐
  │ internal ALB :8200              │         │ internal ALB :8200              │
  │   └─ TG health /v1/sys/health   │         │   └─ TG (no active targets yet) │
  │ ECS Fargate: Vault x3 (active)  │         │ ECS Fargate: Vault x0 (warm)    │
  │   Service Connect :8201         │         │   Service Connect :8201         │
  │ Aurora PostgreSQL (WRITER) ─────┼──repl─▶│ Aurora PostgreSQL (read-only)   │
  │ KMS MRK (seal, primary) ────────┼──repl─▶│ KMS MRK replica (same key id)   │
  │ Secrets Manager (db, recovery)──┼──repl─▶│ Secrets Manager (replicas)      │
  │ Route53 private zone            │         │ Route53 private zone            │
  └─────────────────────────────────┘         └─────────────────────────────────┘
```

Why this shape:

- **One active Vault cluster.** OSS Vault is single-cluster; multi-region
  active/active needs Vault Enterprise replication. With a shared, replicated
  storage backend the only correct topology is one active cluster (Region 1)
  and a passive DR region brought online on failover.
- **One multi-region KMS key, not one-per-region.** Auto-unseal stores the
  encrypted root key *inside* the storage backend, which Aurora replicates to
  Region 2. A separate DR key could not decrypt it. A KMS multi-region key
  (primary in R1, replica in R2) shares key id + material, so the DR cluster
  can unseal the replicated data.
- **Aurora Global Database** gives one writable region and read-only
  secondaries with sub-second replication. The DR Vault stays at
  `desired_count = 0` until the secondary is promoted, because writing through
  a read-only/async replica would break Vault's HA lock consistency.

Full reasoning: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Layout

```
modules/
  networking/   VPC, public/private subnets, NAT, SGs, internal ALB + TG + listener
  kms/          multi-region seal key (primary | replica) + regional data key
  aurora/       Aurora global cluster (primary) / secondary join + instances
  secrets/      DB credentials (generated) + recovery-keys secret + replication
  vault/        ECS cluster, task def, service, Service Connect, IAM, entrypoint
  dns/          Route53 private hosted zone + ALB alias
  bootstrap/    in-VPC one-shot: schema creation + vault operator init (image + task)
regions/
  primary/      Region 1 root (active) — creates global cluster, runs bootstrap
  dr/           Region 2 root (warm DR) — joins global cluster, Vault at 0
.github/workflows/
  validate.yml  fmt + validate both roots on PRs (no AWS creds)
  deploy.yml    apply primary -> build/push bootstrap image -> run bootstrap -> apply dr
  destroy.yml   destroy dr -> destroy primary (reverse order)
  failover.yml  promote Aurora secondary -> scale up DR Vault
cloudformation/
  github-oidc.yaml   one-time OIDC provider + deploy role (apply in console)
```

## Setup (one-time)

The workflows run entirely on GitHub runners and authenticate to AWS with OIDC —
**no AWS credentials are stored in GitHub.** One manual step plants the trust:

1. **Apply the trust anchor.** In the AWS console, create a CloudFormation stack
   from [`cloudformation/github-oidc.yaml`](cloudformation/github-oidc.yaml)
   (parameters: `GitHubOrg`, `GitHubRepo`). It creates the GitHub OIDC provider
   and the deploy role, and outputs `RoleArn`. This is the only step that needs
   pre-existing AWS access — establishing the first OIDC trust requires an
   already-authenticated principal.
2. **Set repo variables** (Settings → Actions → Variables) — all non-sensitive,
   no secrets:

   | Variable | Value |
   |----------|-------|
   | `AWS_DEPLOY_ROLE_ARN` | the stack's `RoleArn` output |
   | `PRIMARY_REGION` / `DR_REGION` | active / DR regions |
   | `TF_STATE_BUCKET` / `TF_LOCK_TABLE` | state bucket + lock table names |
   | `TF_STATE_BUCKET_REGION` | region the state bucket lives in |

The state bucket and lock table don't need to pre-exist — the **deploy** workflow
creates them (idempotently) before `terraform init`.

## Deploy

Order is **primary first, then DR** (DR consumes the primary's seal key, global
cluster, and replicated secret).

Run the **deploy** workflow with `target = both`. It assumes the OIDC role,
ensures the state backend exists, applies primary, builds and pushes the
bootstrap image to ECR, runs the bootstrap task (and fails if it exits non-zero),
then applies DR.

<details>
<summary>Manual CLI equivalent</summary>

```bash
# 1. Primary
cd regions/primary
cp terraform.tfvars.example terraform.tfvars   # edit values
terraform init -backend-config=...              # see backend.tf
terraform apply -var region=us-east-1 -var dr_region=us-west-2

# 2. Build + push the bootstrap image, then run it in-VPC (see deploy.yml for the
#    exact aws ecs run-task invocation). This creates the Postgres schema and
#    runs `vault operator init`, writing recovery keys to Secrets Manager.

# 3. DR (uses primary outputs)
cd ../dr
terraform init -backend-config=...
terraform apply \
  -var region=us-west-2 \
  -var primary_seal_key_arn=$(terraform -chdir=../primary output -raw seal_key_arn) \
  -var global_cluster_identifier=$(terraform -chdir=../primary output -raw global_cluster_identifier)
```
</details>

### What to expect during bootstrap

The PostgreSQL backend requires its tables (`vault_kv_store`, `vault_ha_locks`)
to exist before Vault starts — Vault never creates them. Immediately after the
first apply, the Vault tasks **crash-loop** until the bootstrap task creates the
schema. Once the schema exists, the tasks come up sealed and uninitialized
(`/v1/sys/health` → 501) but register as healthy targets, so the bootstrap task
reaches them through the private ALB and runs `operator init`. Vault then
auto-unseals via KMS, the active node serves 200, and the service converges.

After bootstrap, retrieve the recovery material from Secrets Manager
(`vault-primary/vault/recovery`) and **revoke the initial root token** once
auth backends are configured.

## Failover

See [`docs/OPERATIONS.md`](docs/OPERATIONS.md). In short: run the **failover**
workflow (`switchover` for planned, `failover` for an outage). It promotes the
DR Aurora cluster and scales up DR Vault, which auto-unseals against the
replicated data with the replica KMS key.

## Validation

The **validate** workflow runs `terraform fmt -check` and `terraform validate`
on both roots for every PR (no AWS credentials needed). The stack has been
deployed end-to-end in a development account, but it is **not security hardened**
and has not been run at production scale. Run `terraform plan` against your own
account and review every default in `terraform.tfvars.example` and every
[security caveat](#security-caveats-read-before-production) before relying on it.

## Security caveats (read before production)

- **ALB-terminated TLS / `tls_disable` on the listener.** The Vault listener
  runs plaintext behind the ALB for simplicity. For production, use end-to-end
  TLS (ACM cert on the ALB + a TLS listener on Vault, target group HTTPS).
- **`disable_mlock = true`.** Fargate can't grant `IPC_LOCK`. Ensure the host
  has no swap.
- **Recovery keys + root token in Secrets Manager.** Convenient but co-locates
  unseal-adjacent material with the cloud that holds the KMS key. Consider
  splitting recovery shares to separate custodians.
- **`deletion_protection = false` and `skip_final_snapshot = true`** so the
  destroy workflow works. Flip both for production.
- **`sslmode=require`** (not `verify-full`) on the Postgres connection. Use
  `verify-full` with the RDS CA bundle in production.
- **Vault task runs as root.** The `vault:2.0.x` binary ships with the
  `cap_ipc_lock` file capability, which Fargate can't grant; the entrypoint
  strips it before exec (needs root) since `disable_mlock` makes it unnecessary.
  For production, bake a custom image with the capability removed at build time
  and run as a non-root user.
- **`hashicorp/vault:2.0.1` CE** lacks artifacts for some architectures; the
  task pins `linux/amd64`. Bump to `2.0.2` when released.

# Vault HA on AWS (Fargate + Aurora Global Database)

HashiCorp Vault Community Edition (`hashicorp/vault:2.0.1`) deployed on AWS ECS
Fargate, with Aurora PostgreSQL as the HA storage backend, AWS KMS auto-unseal,
and a warm standby in a second region. Terraform defines the infrastructure and
GitHub Actions workflows deploy, promote, and destroy it.

> **Status:** validated by a successful end-to-end deploy in a development
> account (primary, bootstrap, and DR). **It is not security hardened** and has
> not been run at production scale. It carries deliberate development
> trade-offs: an internet-facing load balancer, no TLS by default, a root
> container, recovery material in Secrets Manager, and no deletion protection.
> Do not deploy to production without addressing every item under
> [Security caveats](#security-caveats).

## Architecture

```
        Primary region (active)                      DR region (warm standby)
  ┌──────────────────────────────────┐         ┌──────────────────────────────────┐
  │ ALB, internet-facing, HTTP :8200 │         │ ALB, internal, HTTP :8200        │
  │   optional HTTPS :443            │         │   target group has no targets    │
  │ ECS Fargate: 2 Vault tasks       │         │ ECS Fargate: 0 Vault tasks       │
  │   1 active, 1 standby            │         │   service defined, scaled to 0   │
  │ Aurora PostgreSQL (writer) ──────┼──repl──▶│ Aurora PostgreSQL (read-only)    │
  │ KMS multi-Region key (primary) ──┼──repl──▶│ KMS multi-Region key (replica)   │
  │ Secrets Manager secrets ─────────┼──repl──▶│ Secrets Manager replicas         │
  │ Route 53 private zone            │         │ Route 53 private zone            │
  └──────────────────────────────────┘         └──────────────────────────────────┘
```

One Vault cluster is active at a time. The primary region serves requests. The
DR region holds replicated data and a Vault service scaled to zero tasks.

Why this shape:

- **One active Vault cluster.** Vault Community Edition has no replication
  between clusters. With one shared, replicated database, the DR copy is
  read-only, so Vault there cannot take the leader lock until that copy is
  promoted.
- **One multi-Region KMS key, not one key per region.** Auto-unseal stores the
  encrypted root key inside the storage backend, and Aurora replicates it to
  the DR region. A KMS multi-Region key has the same key ID and key material in
  both regions, so Vault in the DR region can decrypt the replicated root key.
  A separate DR key could not.
- **Two Vault tasks, not three.** An odd node count matters for Integrated
  Storage (Raft), where the Vault nodes form the consensus group. With an
  external database, Aurora holds the state and leadership is a lease on one
  row in the `vault_ha_locks` table. Two tasks in two availability zones give
  one active node and one standby. A third task would be a second idle standby.
- **Aurora Global Database.** One region is writable and the other receives
  changes through asynchronous replication. Promoting the DR cluster is one API
  call.

Full design: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Layout

```
modules/
  networking/   VPC, public and private subnets, NAT, security groups, ALB, target group, listeners
  kms/          multi-Region seal key (primary or replica) and a regional data key
  aurora/       Aurora global cluster (primary) or secondary cluster, plus instances
  secrets/      generated database credentials, recovery secret, cross-region replication
  vault/        ECS cluster, task definition, service, IAM roles, entrypoint script
  dns/          Route 53 private hosted zone and ALB alias record
  bootstrap/    one-time in-VPC task: creates the schema and initializes Vault
regions/
  primary/      primary region root: creates the global cluster and the bootstrap task
  dr/           DR region root: joins the global cluster, Vault at 0 tasks
.github/workflows/
  validate.yml  fmt and validate on both roots, for pull requests that change .tf files
  deploy.yml    apply primary, build and push bootstrap image, run bootstrap, apply DR
  destroy.yml   destroy DR, then primary
  failover.yml  promote the Aurora secondary, scale up DR Vault
cloudformation/
  github-oidc.yaml   one-time GitHub OIDC provider and deploy role
```

## Setup (one-time)

The workflows run on GitHub-hosted runners and authenticate to AWS with OIDC.
**No AWS credentials are stored in GitHub.** One manual step establishes the
trust:

1. **Apply the trust anchor.** In the AWS console, create a CloudFormation stack
   from [`cloudformation/github-oidc.yaml`](cloudformation/github-oidc.yaml)
   (parameters: `GitHubOrg`, `GitHubRepo`). It creates the GitHub OIDC provider
   and the deploy role, and outputs `RoleArn`. An account can hold only one
   GitHub OIDC provider. When one already exists, pass its ARN as
   `ExistingOidcProviderArn` and the stack reuses it. This is the only step that needs
   existing AWS access, because creating the first OIDC trust requires an
   already authenticated principal.
2. **Set one repo secret** (Settings → Actions → Secrets). It is a role ARN,
   not a credential. GitHub masks secrets in workflow logs, which keeps the
   account ID in the ARN out of them:

   | Secret                | Value                        |
   | --------------------- | ---------------------------- |
   | `AWS_DEPLOY_ROLE_ARN` | the stack's `RoleArn` output |

3. **Set repo variables** (Settings → Actions → Variables):

   | Variable                            | Value                             |
   | ----------------------------------- | --------------------------------- |
   | `PRIMARY_REGION` / `DR_REGION`      | primary and DR regions            |
   | `TF_STATE_BUCKET` / `TF_LOCK_TABLE` | state bucket and lock table names |
   | `TF_STATE_BUCKET_REGION`            | region the state bucket lives in  |

The state bucket and lock table do not need to exist beforehand. The **deploy**
workflow creates them if they are missing.

## Deploy

Run the **deploy** workflow with `target = both`. Its steps, in order:

1. Assume the deploy role through OIDC.
2. Create the Terraform state bucket and lock table if they are missing.
3. Apply the primary root.
4. Build the bootstrap image and push it to ECR.
5. Run the bootstrap task and fail if it exits with an error.
6. Apply the DR root.

The primary region comes first because the DR root takes the seal key ARN and
the global cluster identifier from the primary root's outputs.

The `client_cidr` input sets which public address may reach Vault. The primary
load balancer is internet-facing, and its security group admits only this
range. A bare address is treated as a `/32`, and a `/0` range is rejected. When
the input is blank, no client can reach Vault. To find the public address of
the current machine:

```bash
curl https://checkip.amazonaws.com
```

The optional `domain_name` input adds HTTPS to the primary region. It expects a
fully qualified name, such as `vault.example.com`, whose parent Route 53 public
hosted zone already exists in the account. The stack then creates an ACM
certificate, a listener on 443, and a redirect from 80. When the input is
empty, Vault is served over HTTP on port 8200 only.

The primary root's `vault_endpoint` output is the address to use as
`VAULT_ADDR`.

### What to expect during bootstrap

Vault's PostgreSQL backend requires its tables (`vault_kv_store`,
`vault_ha_locks`) to exist before Vault starts. Vault does not create them.

1. After the first apply, the Vault tasks start and exit repeatedly until the
   bootstrap task creates the tables.
2. The tasks then start sealed and uninitialized. The load balancer health
   check is configured to treat that state as healthy, so the tasks stay
   registered.
3. The bootstrap task reaches Vault through its private DNS name and
   initializes it.
4. Vault unseals through KMS and one task becomes active.

The bootstrap task writes the recovery keys and the initial root token to the
Secrets Manager secret `vault-primary/vault/recovery`. Revoke the initial root
token once an auth method is configured.

## Failover

Run the **failover** workflow. `mode = switchover` is for a planned move while
the primary region is healthy. `mode = failover` is for a primary region that
is unavailable, and loses any change not yet replicated. The workflow promotes
the DR Aurora cluster and scales the DR Vault service up. The new tasks unseal
with the replica KMS key against the replicated data.

The workflow does not redirect clients and does not stop Vault in the old
primary region. See [`docs/OPERATIONS.md`](docs/OPERATIONS.md) for the full
procedure and for teardown.

## Validation

The **validate** workflow runs `terraform fmt -check` and `terraform validate`
on both roots for every pull request that changes a `.tf` file. It needs no AWS
credentials.

The stack has been deployed end to end in a development account. It is **not
security hardened** and has not been run at production scale.

## Security caveats

Each item is a deliberate development default. All of them need a decision
before production use.

- **The primary load balancer is internet-facing.** Its security group admits
  only the `client_cidr` range given to the deploy workflow, and nothing when
  that input is blank. An internal load balancer reached over private
  connectivity is the stronger arrangement.
- **No TLS by default.** Without `domain_name`, clients reach Vault over HTTP on
  port 8200. With `domain_name`, TLS ends at the load balancer and the HTTP
  listener on 8200 remains.
- **The Vault listener has TLS disabled.** Traffic between the load balancer and
  the Vault tasks is plaintext inside the VPC. End-to-end TLS needs a TLS
  listener on Vault and an HTTPS target group.
- **Memory locking is off (`disable_mlock = true`).** Fargate cannot grant
  `IPC_LOCK`.
- **The Vault task runs as root.** The entrypoint removes the `cap_ipc_lock`
  file capability from the Vault binary before starting it, and that requires
  root. A custom image with the capability removed at build time could run as a
  non-root user.
- **Recovery keys and the initial root token share one Secrets Manager
  secret**, in the same account as the seal key, and replicated to the DR
  region. Separate custodians for the recovery shares are the stronger
  arrangement.
- **Vault connects to Aurora as the master user**, and the generated password
  is present in the Terraform state file.
- **`sslmode=require`** on the PostgreSQL connection encrypts it without
  verifying the server certificate. `verify-full` with the RDS CA bundle does
  both.
- **Deletion safeguards are off** so the destroy workflow completes:
  `deletion_protection = false`, `skip_final_snapshot = true`, and a secret
  recovery window of 0 days.
- **The deploy role is broad.** It has full access to each AWS service the stack
  uses, on all resources, and by default trusts every branch and tag of the
  repository. The `SubjectClaimFilter` parameter narrows the trust.
- **No Vault audit device is configured.**

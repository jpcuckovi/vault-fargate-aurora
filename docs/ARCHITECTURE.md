# Architecture

This repository deploys one HashiCorp Vault Community Edition cluster on AWS.
Vault runs as ECS Fargate tasks, stores its data in Aurora PostgreSQL, and
unseals itself with AWS KMS. A second AWS region holds a warm standby that is
brought online by promoting its copy of the database.

Two terms are used throughout:

- **Primary region**: the region where Vault serves requests.
- **DR region**: the standby region. It holds replicated data and a Vault
  service scaled to zero tasks.

## Topology

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

Each region is a separate Terraform root (`regions/primary`, `regions/dr`) with
its own state file. Both roots call the same modules with a different role.

| Component      | Primary region                  | DR region                 |
| -------------- | ------------------------------- | ------------------------- |
| VPC            | `10.10.0.0/16`, two zones       | `10.20.0.0/16`, two zones |
| Load balancer  | Internet-facing, public subnets | Internal, private subnets |
| Vault tasks    | 2 (one active, one standby)     | 0 until promotion         |
| Aurora cluster | Writable, 2 instances           | Read-only, 2 instances    |
| Seal key       | KMS multi-Region key            | Replica of the same key   |
| Data key       | Regional KMS key                | Separate regional KMS key |
| Secrets        | Credentials, recovery material  | Replicas of both          |
| Private DNS    | `vault.vault.internal`          | Same name, DR VPC only    |
| Bootstrap task | Present                         | Absent                    |
| HTTPS listener | Optional (`domain_name`)        | Not available             |

The two VPCs are not connected to each other. No peering, transit gateway, or
shared DNS zone exists between the regions.

## Request path

1. A client connects to the ALB on port 8200 over HTTP. When `domain_name` is
   set, the primary ALB also listens on 443 with an ACM certificate and
   redirects port 80 to 443. Port 8200 stays open over HTTP in both cases.
2. The ALB forwards to any registered Vault task on port 8200 over HTTP. The
   target group registers task IPs directly (`target_type = "ip"`).
3. If the task is the active node, it serves the request.
4. If the task is the standby, it forwards the request to the active node over
   port 8201. Vault encrypts this hop with TLS certificates that it generates
   and manages itself.

Every running task is a healthy target, including the standby. The health check
path sets query parameters so that `/v1/sys/health` returns 200 for an active,
standby, sealed, or uninitialized node. This is required because the same
target group health also drives ECS task replacement. With a plain health check,
ECS would stop the standby (which answers 429) and would stop every task of a
new deployment before initialization (which answers 501).

## Storage and leader election

Vault uses its `postgresql` storage backend with `ha_enabled = "true"`. Two
tables hold all state:

| Table            | Content                                       |
| ---------------- | --------------------------------------------- |
| `vault_kv_store` | Every Vault storage entry, encrypted by Vault |
| `vault_ha_locks` | One row naming the active node and its expiry |

Leader election is a lease on the row in `vault_ha_locks`. The node that holds
an unexpired row is active. The other node retries until the row expires or is
released. No Raft or other consensus protocol runs between the Vault nodes.

The active node also records its own cluster address in the storage backend.
The standby reads that address from the database and connects to it directly.
For this reason each task advertises its own network interface IP, read from
the ECS task metadata endpoint at start:

| Setting        | Value                    |
| -------------- | ------------------------ |
| `api_addr`     | `http://<task-ip>:8200`  |
| `cluster_addr` | `https://<task-ip>:8201` |

The ECS service also registers port 8201 in an ECS Service Connect namespace.
Request forwarding does not depend on it, because the standby uses the address
that the active node stored.

Vault does not create the two tables. A one-time bootstrap task creates them
(see [Bootstrap](#bootstrap)).

### Aurora Global Database

The database is an Aurora PostgreSQL 16.6 global cluster. The primary region
holds the writable cluster. The DR region holds a secondary cluster that
receives changes through Aurora's asynchronous storage-level replication and
rejects writes. Write forwarding is not enabled. Each cluster has two
`db.r6g.large` instances.

Vault in each region is configured with its own region's cluster endpoint. In
the DR region that endpoint is read-only until promotion and writable after it,
so promotion needs no change to the Vault configuration.

## Seal and unseal

Vault encrypts its root key with a KMS key and stores the resulting ciphertext
in the storage backend. At start, Vault reads the ciphertext, asks KMS to
decrypt it, and unseals without operator input.

Aurora replicates that ciphertext to the DR region unchanged. The DR region
must therefore be able to decrypt with the same key material. The seal key is a
KMS multi-Region key: the primary region creates it and the DR region creates a
replica. Both share one key ID and one set of key material. A separate key per
region would leave the DR region unable to unseal the replicated data.

Because auto-unseal is in use, `vault operator init` returns recovery keys in
place of unseal keys. Recovery keys authorize sensitive operations such as
generating a new root token. They cannot unseal Vault.

## Why one active region

Two facts fix the design at one active cluster with a standby region.

- **The DR database is read-only.** A Vault task in the DR region could not
  write the lock row, so it could never become active. It also could not act as
  a standby for the primary region, because it has no network path to the
  active node.
- **Community Edition has no cross-cluster replication.** Running two
  independent Vault clusters that replicate to each other requires Vault
  Enterprise. This repository does not implement that design.

The DR Vault service is therefore defined but held at `desired_count = 0`.

## Node count

The primary region runs two Vault tasks in two availability zones. Two is the
intended number, not a reduced quorum.

An odd node count matters for Vault's Integrated Storage, where the Vault nodes
form a Raft group and must hold a majority. With PostgreSQL storage, durability
and replication belong to Aurora. The Vault tasks hold no state of their own.
One holds the lock and the other waits for it. That works the same with two
nodes as with five.

A standby in Community Edition serves no requests itself. It forwards all of
them to the active node. A third task would add cost and one more idle
forwarder. To handle more load, raise `task_cpu` and `task_memory` on the
active node before raising the task count.

The ECS service ignores Terraform changes to `desired_count`. The task count is
an operational control, changed by the failover workflow and not reset by a
later `terraform apply`.

## Compute

Vault runs the stock `hashicorp/vault:2.0.1` image on Fargate, pinned to
`linux/amd64`, with 1 vCPU and 2 GiB per task. The task definition replaces the
image entrypoint with `modules/vault/entrypoint.sh`, which does the following:

1. Reads the task IP from the ECS task metadata endpoint.
2. Checks that all required environment variables are set.
3. Writes the Vault configuration file, including the database connection URL.
4. Removes the `cap_ipc_lock` file capability from the Vault binary.
5. Starts `vault server`.

Step 4 exists because Fargate cannot grant `IPC_LOCK`. The Vault 2.0 binary
carries that capability as a file attribute, and executing it fails on Fargate
while the attribute is present. Removing a file capability requires root, so
the container runs as user 0. Memory locking is turned off in the Vault
configuration (`disable_mlock = true`) for the same reason.

The Vault web UI is enabled.

## Networking

Each region has one VPC with two public and two private subnets. Vault tasks
and Aurora instances run in the private subnets with no public IP. Each
availability zone has its own NAT gateway. Tasks reach KMS, Secrets Manager,
ECR, and CloudWatch Logs through NAT. No VPC endpoints are defined.

Security group rules:

| Security group    | Inbound                             | Outbound                |
| ----------------- | ----------------------------------- | ----------------------- |
| ALB               | 8200 from `client_ingress_cidrs`    | 8200 to the Vault tasks |
| ALB, primary only | 8200 from the NAT gateway addresses |                         |
| Vault tasks       | 8200 from the ALB, 8201 from itself | All destinations        |
| Aurora            | 5432 from the Vault tasks           | None defined            |

When `domain_name` is set, the ALB group also allows 443 and 80 from
`client_ingress_cidrs`.

`client_ingress_cidrs` is empty by default in the primary root, which creates
no client rule. The deploy workflow fills it from its `client_cidr` input, a
single public address or range, and rejects a `/0` range. In the DR root it
defaults to the DR VPC range.

The primary ALB is internet-facing, so its DNS name resolves to public
addresses even from inside the VPC. A task in a private subnet reaches it
through a NAT gateway. The ALB group therefore also allows port 8200 from the
NAT gateway addresses, which lets the bootstrap task reach Vault when no client
range is set.

Each VPC has a Route 53 private hosted zone, `vault.internal`, with one alias
record, `vault.vault.internal`, that points at that region's ALB. When
`domain_name` is set, the primary root also creates a public alias record and a
DNS-validated ACM certificate in an existing public hosted zone.

## Keys and secrets

| Item                      | Type                 | Created by   | Used for                          |
| ------------------------- | -------------------- | ------------ | --------------------------------- |
| Seal key                  | KMS multi-Region key | Primary root | Vault auto-unseal                 |
| Seal key replica          | KMS replica key      | DR root      | Vault auto-unseal after promotion |
| Data key                  | KMS key, per region  | Each root    | Aurora storage, primary secrets   |
| `<prefix>/aurora/master`  | Secrets Manager      | Primary root | Database login for Vault          |
| `<prefix>/vault/recovery` | Secrets Manager      | Primary root | Output of Vault initialization    |

`<prefix>` is the `name_prefix` variable, `vault-primary` by default.

The database password is generated by Terraform (32 alphanumeric characters)
and stored in the credentials secret. It is also present in the primary
Terraform state file. ECS reads the secret at task start and passes the password
to the container as an environment variable. Vault connects to Aurora as the
cluster's master user.

Both secrets are replicated to the DR region. The Aurora secondary inherits the
global cluster's master credentials, so Vault in the DR region must use the same
password. The DR root looks up the replicated secret by name. The replicas are
encrypted with the AWS managed Secrets Manager key in the DR region.

The recovery secret is created with a placeholder value. The bootstrap task
replaces it with the full response from Vault initialization, which contains
the recovery keys and the initial root token.

## IAM

| Role                | Assumed by            | Permissions                                         |
| ------------------- | --------------------- | --------------------------------------------------- |
| Vault execution     | ECS, at task start    | Pull image, write logs, read the credentials secret |
| Vault task          | The Vault process     | Use the seal key, nothing else                      |
| Bootstrap execution | ECS, at task start    | Same as the Vault execution role                    |
| Bootstrap task      | The bootstrap script  | Write the recovery secret                           |
| Deploy              | GitHub Actions (OIDC) | Full access to every AWS service the stack uses     |

The Vault process has no access to Secrets Manager. Its only AWS permission is
use of the seal key.

## Bootstrap

A new deployment needs two actions that Terraform cannot perform: creating the
PostgreSQL tables and initializing Vault. Aurora accepts connections only from
the Vault task security group, so both run inside the VPC as a single one-time
Fargate task. The deploy workflow builds the task image from
`modules/bootstrap`, pushes it to an ECR repository, runs the task, and fails
if the task exits with an error.

The sequence on a first deployment:

1. Terraform creates the infrastructure. The Vault tasks start and exit
   repeatedly, because the tables do not exist yet.
2. The bootstrap task creates `vault_kv_store` and `vault_ha_locks`.
3. The Vault tasks start successfully. They are sealed and uninitialized, and
   the health check reports them healthy.
4. The bootstrap task confirms that it can write the recovery secret, then
   calls Vault through `vault.vault.internal` and initializes it with 5
   recovery shares and a threshold of 3.
5. The bootstrap task writes the initialization response to the recovery
   secret.
6. Vault unseals through KMS. One task takes the lock and becomes active.

The task is safe to run again. Table creation uses `IF NOT EXISTS`, and the
task exits without changes when Vault reports that it is already initialized.

The DR region has no bootstrap task. It receives the tables, the Vault data, and
the encrypted root key through Aurora replication.

## Disaster recovery

The DR region is a warm standby. Everything except running Vault tasks exists
ahead of time: network, load balancer, Aurora secondary, seal key replica,
replicated secrets, and an ECS service with zero tasks.

Promotion is one manually started workflow, `failover`. It calls only the DR
region and does not read Terraform state, so it does not depend on the primary
region or on the region that holds the state bucket. It addresses the DR
resources by the names the Terraform defaults produce. It has two modes:

| Mode         | AWS operation                               | Intended use                  |
| ------------ | ------------------------------------------- | ----------------------------- |
| `switchover` | `switchover-global-cluster`                 | Planned move, primary healthy |
| `failover`   | `failover-global-cluster --allow-data-loss` | Primary region unavailable    |

The workflow then performs these steps:

1. Waits until the global cluster reports the DR Aurora cluster as the writer.
2. Sets the DR Vault service to the requested task count, 2 by default.
3. Waits for the ECS service to report stable.

The new tasks read the replicated root key ciphertext, decrypt it with the seal
key replica, and unseal. One task takes the lock and becomes active. No Vault
initialization or key ceremony is needed, because the DR region holds the same
Vault data as the primary region.

The following steps are not automated:

- **Stopping Vault in the old primary region.** The workflow does not scale
  that service down.
- **Redirecting clients.** Each region has its own endpoint. The DR ALB is
  internal and reachable only from inside the DR VPC. No DNS record moves
  between regions.
- **Failing back.** The old primary region must be rejoined to the global
  cluster as a secondary before a switch back.
- **Updating Terraform roles.** Each root has a fixed role (`primary` or
  `secondary`). After a promotion, the code no longer describes which region is
  the writer.

Data written in the primary region and not yet replicated when an unplanned
failover starts is lost. Aurora replication between regions is asynchronous.

## Delivery

All changes are applied by GitHub Actions workflows that are started manually.

| Workflow   | Trigger                      | Action                                 |
| ---------- | ---------------------------- | -------------------------------------- |
| `validate` | Pull requests changing `.tf` | Format check and validate, both roots  |
| `deploy`   | Manual                       | Apply primary, run bootstrap, apply DR |
| `failover` | Manual                       | Promote DR Aurora, scale up DR Vault   |
| `destroy`  | Manual, typed confirmation   | Destroy DR, then primary               |

**Authentication.** The workflows hold no AWS credentials. A CloudFormation
template (`cloudformation/github-oidc.yaml`), applied once by hand, creates a
GitHub OIDC identity provider and a deploy role. Each workflow run exchanges a
short-lived GitHub token for temporary credentials on that role. By default the
role trusts every branch, tag, and environment of the repository. The
`SubjectClaimFilter` parameter narrows that.

**State.** Each root keeps its state under its own key in one S3 bucket, with a
DynamoDB table for locking. The deploy workflow creates both if they are
missing. The bucket is versioned, encrypted with KMS, and blocks public access.

**Ordering.** The DR root depends on two values from the primary root: the seal
key ARN and the global cluster identifier. The deploy workflow reads them from
the primary root's outputs and passes them as variables. Deployment therefore
runs primary first. Destruction runs in reverse, and the destroy workflow
detaches every read-only cluster from the global cluster before it destroys
anything.

**Concurrency.** The deploy, failover, and destroy workflows share one
concurrency group, so only one of them runs at a time.

## Observability

- Vault and bootstrap container output goes to CloudWatch Logs with 30-day
  retention.
- Aurora exports its PostgreSQL log to CloudWatch Logs.
- ECS Container Insights is enabled on the cluster.
- No Vault audit device is configured. Enabling one is a Vault configuration
  step outside this repository.

## Limits of this design

The stack was built and deployed in a development account. It favors a
repeatable create and destroy cycle over hardening. The README lists each
security trade-off. The structural limits are:

- One Vault cluster is active at a time. The DR region adds recovery, not
  capacity.
- Recovery is started by a person. No health check triggers promotion.
- The two regions share no network path and no client-facing DNS name.
- The Vault listener has no TLS. Traffic between the ALB and the tasks is
  plaintext inside the VPC.
- Vault connects to the database as the master user with `sslmode=require`,
  which encrypts the connection without verifying the server certificate.

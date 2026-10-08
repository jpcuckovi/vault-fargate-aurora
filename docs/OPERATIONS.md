# Operations Runbook

## Client access

The primary load balancer is internet-facing. Its security group admits only
the address range passed to the **deploy** workflow as `client_cidr`. When the
input is blank, no client can reach Vault.

To find the public address of the current machine:

```bash
curl https://checkip.amazonaws.com
```

Run the **deploy** workflow with `target = primary` and that address as
`client_cidr`. A bare address is treated as a `/32`. Each deploy run replaces
the previous value, so a run with a blank `client_cidr` removes client access.

The address must be entered by hand. The workflow runs on a GitHub-hosted
runner, so an address detected inside the workflow would be the runner's.

## Bootstrap (first deploy only)

The bootstrap is a one-time Fargate task that runs inside the VPC. Aurora
accepts connections only from the Vault task security group, so a GitHub-hosted
runner cannot create the schema. The task does the following:

1. Creates the PostgreSQL schema (`vault_kv_store`, `vault_ha_locks`). The
   statements use `IF NOT EXISTS`.
2. Waits for Vault to respond.
3. Exits without changes if Vault is already initialized.
4. Writes a marker to the recovery secret, to confirm the secret is writable
   before initialization produces keys that exist nowhere else.
5. Initializes Vault with `recovery_shares=5` and `recovery_threshold=3`.
6. Writes the recovery keys and the initial root token to the Secrets Manager
   secret `<prefix>/vault/recovery`.

The task reaches Vault through the private DNS name. In the primary region that
name resolves to the load balancer's public addresses, so the request leaves
through a NAT gateway. The load balancer security group admits the NAT gateway
addresses for this purpose.

The **deploy** workflow builds the bootstrap image, pushes it to ECR, and runs
the task after applying the primary root.

After bootstrap, read the recovery material. The default prefix is
`vault-primary`:

```bash
aws secretsmanager get-secret-value --secret-id vault-primary/vault/recovery --query SecretString --output text
```

Configure an auth method, then revoke the initial root token:

```bash
vault token revoke <root_token>
```

## Health semantics

The target group health drives both load balancer routing and ECS task
replacement, so every running node must report healthy, not only the active
one. The health check path carries query parameters that make `/v1/sys/health`
return 200 for a standby, uninitialized, or sealed node:

```
/v1/sys/health?standbyok=true&perfstandbyok=true&uninitcode=200&sealedcode=200&drsecondarycode=200
```

Keep these parameters. Without them the endpoint returns the codes below, and
the health check accepts only 200.

| Code | Meaning                       | Effect without the parameters             |
| ---- | ----------------------------- | ----------------------------------------- |
| 200  | Initialized, unsealed, active | Healthy                                   |
| 429  | Unsealed standby              | ECS stops the standby task                |
| 501  | Not initialized               | No healthy target, bootstrap cannot start |
| 503  | Sealed                        | ECS stops a task that is still unsealing  |

A standby forwards client requests to the active node over port 8201, so a
request succeeds whichever task the load balancer selects.

## Failover (DR promotion)

Run the **failover** workflow with one of two modes:

| Mode         | Use                           | Data loss                        |
| ------------ | ----------------------------- | -------------------------------- |
| `switchover` | Planned move, primary healthy | None                             |
| `failover`   | Primary region unavailable    | Changes not yet replicated to DR |

The workflow promotes the DR Aurora cluster, waits until the global cluster
reports it as the writer, sets the DR Vault service to `dr_desired_count` tasks (2 by default), and waits
for the service to stabilize. The DR tasks unseal with the replica KMS key
against the replicated storage.

The workflow calls only the DR region and does not read Terraform state. It
uses the default resource names (`vault-global`, `vault-dr-aurora`,
`vault-dr-vault`). If `name_prefix` or `global_cluster_identifier` is changed
from its default, change the names at the top of the workflow file to match.

The DR load balancer is internal. The remaining steps are manual and run from
inside the DR VPC:

1. Verify that `http://vault.vault.internal:8200/v1/sys/health` returns 200.
2. Repoint client traffic to the DR endpoint.
3. Scale the Vault service in the old primary region to 0 once that region is
   reachable. Its database is no longer writable.
4. Before switching back, rejoin the old primary region to the global cluster
   as a secondary.

## Teardown

Run the **destroy** workflow and confirm with the literal text `destroy`. It
destroys the DR region first and the primary region second, the reverse of
deploy. The DR Aurora cluster is a member of the primary's global cluster and
the DR seal key is a replica of the primary key, so neither can outlive the
primary. The workflow first detaches every read-only cluster from the global
cluster. It reads the members from the global cluster, so the order also holds
after a failover, when the DR cluster is the writer.

`deletion_protection` and `skip_final_snapshot` must allow deletion. The
defaults do.

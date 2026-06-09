# Operations Runbook

## Bootstrap (first deploy only)

The bootstrap is an in-VPC one-shot Fargate task (the ALB is private, so a
GitHub-hosted runner cannot reach it). It:

1. Creates the Postgres schema (`vault_kv_store`, `vault_ha_locks`) — idempotent.
2. Waits for Vault to respond and report uninitialized.
3. Runs `operator init` with `recovery_shares=5`, `recovery_threshold=3`.
4. Writes recovery keys + the initial root token to Secrets Manager
   (`<prefix>/vault/recovery`).

The `deploy` workflow builds + pushes the bootstrap image to ECR and runs the
task after `apply`. To run it by hand, mirror the `aws ecs run-task` block in
`.github/workflows/deploy.yml` (cluster, task family, subnets, SG come from the
primary outputs).

After bootstrap:

```bash
aws secretsmanager get-secret-value --secret-id vault-primary/vault/recovery \
  --query SecretString --output text | jq .
# configure auth/secret backends, then:
vault token revoke <root_token>
```

## Health semantics

The target group governs both ALB routing and ECS task lifecycle, so every alive
node must report healthy — not just the active one. The health check path carries
query parameters that make `/v1/sys/health` return 200 for standby,
uninitialized, sealed, and DR-secondary states:

```
/v1/sys/health?standbyok=true&perfstandbyok=true&uninitcode=200&sealedcode=200&drsecondarycode=200
```

Keep these parameters. A bare `matcher = "200"` leaves a fresh Vault (501) with no
healthy target — deadlocking bootstrap — and lets ECS kill standby tasks (429).

| Default code | Meaning                       | Health check |
|------|-------------------------------|------------|
| 200  | initialized, unsealed, active | healthy |
| 429  | unsealed standby              | healthy (forwards to active over 8201) |
| 472/473 | DR / perf standby          | healthy |
| 501  | not initialized               | healthy (lets bootstrap reach Vault) |
| 503  | sealed                        | healthy (auto-unseal in progress) |

Standby nodes forward client requests to the active node over the cluster port,
so client calls resolve to the leader regardless of which task the ALB picks.

## Failover (DR promotion)

Run the `failover` workflow:

- `mode = switchover` — planned, zero data loss; needs a healthy current primary.
- `mode = failover` — unplanned (Region 1 outage); minimal possible data loss.

It promotes the DR Aurora cluster, waits for it to become available, scales up
DR Vault, and waits for the service to stabilize. DR Vault auto-unseals with the
replica KMS key against the replicated storage.

Then:

1. Verify `http://vault.<dr-zone>/v1/sys/health` returns 200.
2. Repoint client traffic to the DR endpoint.
3. When Region 1 recovers, rebuild it as the new secondary (re-add to the global
   cluster) before switching back.

## Teardown

Run the `destroy` workflow (confirm with the literal text `destroy`). It
destroys **DR first, then primary** — the reverse of deploy — because the DR
Aurora cluster is a member of the primary's global cluster and the DR seal key
is a replica of the primary key. `deletion_protection` and
`skip_final_snapshot` must allow deletion (defaults in this scaffold do).

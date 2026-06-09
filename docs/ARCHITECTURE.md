# Architecture & Design Decisions

## Topology: one active cluster + warm DR (Model #1)

A single active Vault cluster runs on a shared Aurora PostgreSQL Global
Database, sealed by one multi-region KMS key, with Region 2 as warm DR. Two
constraints force this shape:

- **Auto-unseal binds the storage backend to one KMS key.** Vault encrypts its
  root key with the KMS key and stores the ciphertext in the storage backend.
  Aurora replicates that ciphertext verbatim to Region 2, so Region 2 must seal
  against the same key material. One multi-region key (primary in R1, replica in
  R2) serves both regions; a separate per-region key cannot decrypt the
  replicated root key.
- **The HA lock requires a single writer.** An active Region 2 node writing
  through the asynchronous read replica violates the read-after-write
  consistency `vault_ha_locks` depends on and risks split brain. Region 2 stays
  at `desired_count = 0` until its Aurora secondary is promoted.

The alternative — two independent clusters, each with its own storage and KMS
key, linked by Vault Enterprise replication (Model #2) — requires a license and
a non-shared storage backend. This repository does not implement it.

## Component decisions

### Storage backend — Aurora PostgreSQL
The PostgreSQL backend supports HA (`ha_enabled`, leader election via
`vault_ha_locks`) and is community-supported. Its tables are **not** auto-created
by Vault, which is why a bootstrap step creates the schema. Aurora Global
Database provides one writable region with sub-second replication to a read-only
secondary, and one-command promotion for DR.

### Auto-unseal — KMS multi-region key
`aws_kms_key` with `multi_region = true` in Region 1; `aws_kms_replica_key` in
Region 2. The replica shares the same key id and material, so the seal stanza
(`seal "awskms"`) in the DR region — pointed at the local region and the same
key id — can decrypt the replicated root key.

### Compute — ECS Fargate
Each task advertises its own ENI IP as `api_addr` (8200) and `cluster_addr`
(8201), read from the ECS task metadata endpoint. The ALB health check queries
`/v1/sys/health` with query parameters that make every alive node (active,
standby, uninitialized, sealed) report healthy. This target group governs both
ALB routing and ECS task lifecycle: standbys stay registered and forward client
requests to the active node over the cluster port (8201), which the task
security group allows to itself.

### DR posture — warm
DR Vault runs at `desired_count = 0`; the read-only Aurora secondary cannot take
the HA lock. On failover the secondary is promoted to writable, DR Vault scales
up, and it auto-unseals against the replicated data and schema using the replica
KMS key. The service sets `ignore_changes = [desired_count]`, so scaling is an
operational lever rather than a Terraform-managed value.

### Credentials
The Aurora secondary inherits the global cluster's master credentials, so the DR
Vault must use the **same** password as the primary. The credentials secret (and
the recovery-keys secret) are therefore replicated into the DR region, and the
DR root reads the replica by name.

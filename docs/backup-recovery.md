# Backup & Recovery

**Backup is meaningless without a tested restore.** This doc covers both: what
gets backed up, how to verify the backup actually works, and how to restore
from it.

The lab has three independent backup concerns:

| Concern | What's protected | Mechanism | Where it lands |
|---|---|---|---|
| **Postgres data** (Keycloak users, sessions, configs, realm data) | continuous WAL + nightly base backups | CNPG `barmanObjectStore` via `cnpg-backup` MinIO user | `s3://cnpg-backups/keycloak/` |
| **Vault secrets** (root token aside, every seeded secret + ESO role + policy) | Raft snapshot of the entire datastore | `vault operator raft snapshot save` daily CronJob | `s3://vault-backups/` |
| **MinIO objects themselves** (the backup target) | local-path PVC, NOT externally replicated in the lab | n/a — this is the lab limitation | host filesystem only |

> **The bootstrap-restore order matters.** Vault must be restored before
> anything else because every other secret depends on it. CNPG needs MinIO
> reachable to fetch its WAL stream during recovery, so MinIO comes second.
> Keycloak's restore is automatic once Postgres + Vault are back.

## Layer 1: Postgres (CNPG) backup

### What's running

A `ScheduledBackup` CR in the keycloak namespace fires daily at 02:00:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata: { name: keycloak-db-daily, namespace: keycloak }
spec:
  schedule: "0 0 2 * * *"
  cluster:  { name: keycloak-db }
```

The Cluster's `backup.barmanObjectStore` config writes to MinIO via the
scoped `cnpg-backup` user. Continuous WAL archiving runs alongside
on every WAL rotation.

### Verify the backup pipeline works (one-shot test)

**Windows / PowerShell:**

```powershell
# 1. Trigger a backup right now (PowerShell here-string; no bash heredoc)
@"
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: keycloak-db-manual-1
  namespace: keycloak
spec:
  cluster:
    name: keycloak-db
"@ | kubectl apply -f -

# 2. Wait for completion (~30-60s)
kubectl -n keycloak get backup keycloak-db-manual-1 -w
# Look for: phase: completed, no error field

# 3. Inspect the actual objects in MinIO
$pod  = kubectl -n minio get pod -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}'
$root = (kubectl -n minio get secret minio-root-credentials -o jsonpath='{.data}' | ConvertFrom-Json)
$u    = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($root.'root-user'))
$p    = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($root.'root-password'))
kubectl -n minio exec $pod -- mc alias set local http://localhost:9000 $u $p
kubectl -n minio exec $pod -- mc ls --recursive local/cnpg-backups/
```

**Linux / macOS / bash:**

```bash
# 1. Trigger a backup right now
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: keycloak-db-manual-1
  namespace: keycloak
spec:
  cluster:
    name: keycloak-db
EOF

# 2. Wait for completion
kubectl -n keycloak get backup keycloak-db-manual-1 -w

# 3. Inspect the actual objects in MinIO
pod=$(kubectl -n minio get pod -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}')
u=$(kubectl -n minio get secret minio-root-credentials -o jsonpath='{.data.root-user}' | base64 -d)
p=$(kubectl -n minio get secret minio-root-credentials -o jsonpath='{.data.root-password}' | base64 -d)
kubectl -n minio exec "$pod" -- mc alias set local http://localhost:9000 "$u" "$p"
kubectl -n minio exec "$pod" -- mc ls --recursive local/cnpg-backups/
```

Expected structure under `cnpg-backups/`:
```
keycloak/base/<backup-id>/data.tar.gz
keycloak/wals/0000000100000000/000000010000000000000001.gz
keycloak/wals/0000000100000000/000000010000000000000002.gz
...
```

If phase is `failed`, the `.status.error` field tells you why. Most common:
`AccessDenied` / `InvalidAccessKeyId`.

### Restore from a CNPG backup (PITR)

Restore is a **new Cluster CR** that bootstraps from the existing backup
object store. The cluster name MUST be different from the original (CNPG
won't overwrite an existing cluster):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: keycloak-db-restored        # NEW name
  namespace: keycloak
spec:
  instances: 1                      # restore as single instance first; scale up after
  imageName: ghcr.io/cloudnative-pg/postgresql:17.6

  bootstrap:
    recovery:
      source: keycloak-db-source
      # Omit recoveryTarget for latest-WAL-replay; include it for PITR:
      # recoveryTarget:
      #   targetTime: "2026-06-03 14:00:00.00+00"

  externalClusters:
    - name: keycloak-db-source
      barmanObjectStore:
        destinationPath: s3://cnpg-backups/keycloak     # MUST match original
        endpointURL: http://minio.minio.svc.cluster.local:9000
        s3Credentials:
          accessKeyId:     { name: cnpg-backup-minio-creds, key: ACCESS_KEY_ID }
          secretAccessKey: { name: cnpg-backup-minio-creds, key: ACCESS_SECRET_KEY }
        wal:  { compression: gzip }
        data: { compression: gzip }

  storage: { size: 2Gi }
```

CNPG will:
1. Pull the latest base backup from `cnpg-backups/keycloak/base/`
2. Replay WAL segments from `cnpg-backups/keycloak/wals/`
3. Either stop at `recoveryTarget.targetTime` (PITR) or replay to the
   latest WAL (full restore)
4. Promote the restored instance to primary

After verification, you can cut Keycloak over by re-pointing the
`Keycloak.spec.db.host` from `keycloak-db-rw` to `keycloak-db-restored-rw`.

**Restore drill** (Stretch S3 in the build plan): automate the above as a
weekly CronJob, validate row counts + a synthetic query against the
restored instance, then delete the ephemeral Cluster CR. An untested
backup is a hope, not a backup.

## Layer 2: Vault Raft snapshot

A daily CronJob (`manifests/vault-backup/cronjob.yaml`, ArgoCD application
`vault-backup`) runs at **03:00** (after CNPG's 02:00 to avoid simultaneous
MinIO writes) and uploads a Raft snapshot to MinIO `s3://vault-backups/`.

The Job uses **two containers** with a shared `emptyDir`:

```
initContainer (hashicorp/vault:1.21.2)
  → login via k8s auth (SA: vault-snapshot, role: vault-snapshot)
  → vault operator raft snapshot save /shared/vault-snapshot.snap
  → chmod 0640 so the upload container (different UID) can read

container (bitnamilegacy/minio-client:2024.11.21)
  → mc cp /shared/vault-snapshot.snap local/vault-backups/vault-snapshot-<ts>.snap
  → mc rm --older-than 7d local/vault-backups/   (retention)
```

The split exists because no single small image carries both the `vault`
CLI and `mc`. Building a custom multi-tool image would have been more
complex than the init-container pattern for this lab.

### Auth model

- **ServiceAccount** `vault-snapshot` in namespace `vault`
- **Vault policy** `vault-snapshot-policy`:
  ```hcl
  path "sys/storage/raft/snapshot" {
    capabilities = ["read"]
  }
  ```
- **Vault Kubernetes auth role** `vault-snapshot`:
  - `bound_service_account_names=vault-snapshot`
  - `bound_service_account_namespaces=vault`
  - `policies=vault-snapshot-policy`
  - `ttl=10m` (short — token only needs to live long enough for one snapshot)

Both the policy and role are seeded by `scripts/ps/init-vault.ps1` (and
`scripts/bash/init-vault.sh`) on first bootstrap. Re-running the script
is idempotent — it doesn't overwrite an existing role.

### MinIO side

- **Bucket** `vault-backups` (provisioned by the MinIO wrapper chart at install time)
- **Scoped user** `vault-sn-*` with **policy** `vault-snapshot-policy`
  restricted to `arn:aws:s3:::vault-backups[/*]` — no access to
  `cnpg-backups` or any other bucket
- **Credentials** seeded in Vault at `secret/minio/vault-snapshot-keys`,
  materialized into the `vault` namespace as the K8s Secret
  `vault-snapshot-minio-creds` by ESO

### Trigger a manual run + verify the snapshot landed in MinIO

**Windows / PowerShell:**

```powershell
$jobName = "vault-snapshot-manual-$(Get-Date -Format yyyyMMddHHmmss)"
kubectl -n vault create job --from=cronjob/vault-snapshot $jobName

# Wait for completion (init container + main container, ~30-45s total)
kubectl -n vault wait --for=condition=complete job/$jobName --timeout=120s

# Inspect both container logs
kubectl -n vault logs job/$jobName -c snapshot
kubectl -n vault logs job/$jobName -c upload

# List vault-backups bucket (self-contained: re-derives MinIO alias)
$pod  = kubectl -n minio get pod -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}'
$root = (kubectl -n minio get secret minio-root-credentials -o jsonpath='{.data}' | ConvertFrom-Json)
$u    = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($root.'root-user'))
$p    = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($root.'root-password'))
kubectl -n minio exec $pod -- mc alias set local http://localhost:9000 $u $p
kubectl -n minio exec $pod -- mc ls --recursive local/vault-backups/
# Should show vault-snapshot-<timestamp>.snap
```

**Linux / macOS / bash:**

```bash
job="vault-snapshot-manual-$(date +%Y%m%d%H%M%S)"
kubectl -n vault create job --from=cronjob/vault-snapshot "$job"
kubectl -n vault wait --for=condition=complete job/"$job" --timeout=120s
kubectl -n vault logs job/"$job" -c snapshot
kubectl -n vault logs job/"$job" -c upload

# Self-contained mc setup
pod=$(kubectl -n minio get pod -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}')
u=$(kubectl -n minio get secret minio-root-credentials -o jsonpath='{.data.root-user}' | base64 -d)
p=$(kubectl -n minio get secret minio-root-credentials -o jsonpath='{.data.root-password}' | base64 -d)
kubectl -n minio exec "$pod" -- mc alias set local http://localhost:9000 "$u" "$p"
kubectl -n minio exec "$pod" -- mc ls --recursive local/vault-backups/
```

### Restore from a Vault snapshot

```bash
# 1. Copy the snapshot file into the new vault-0 pod
kubectl cp 2026-06-03-vault.snap vault/vault-0:/tmp/vault.snap

# 2. From a previously-initialized Vault (root token in hand)
kubectl -n vault exec -it vault-0 -- /bin/sh
vault login <root-token>
vault operator raft snapshot restore /tmp/vault.snap

# 3. Vault is now sealed (snapshot restore re-seals). Unseal:
vault operator unseal <unseal-key-from-original-init>
```

The unseal key for the **restored** Vault is the one from the **original**
init (because Raft snapshot includes the unseal key material). The
`terraform/vault-keys.json` from the original cluster is what's needed.

If `vault-keys.json` is lost, the snapshot is unrecoverable — same posture
as production (unseal key custody is the operator's responsibility). KMS
auto-unseal removes this risk; see `production-gaps.md`.

## Layer 3: MinIO objects (lab limitation)

MinIO's own data sits on a `local-path` PVC backed by the VM's filesystem.
**It is not replicated externally in the lab.** If the VM disk fails or
the VM is destroyed without first migrating MinIO data, every backup
written there (CNPG + Vault snapshots) is lost.

This is the **lab's most significant backup gap**, deliberately accepted to
keep the assessment focused on Keycloak. Production replacements documented
in `production-gaps.md`:

- **`mc replicate`** to a second MinIO cluster in another region/zone
- **MinIO cluster-mirror** for active-active topology
- **Backup to true cloud S3** (AWS / GCS / Azure Blob) for an
  out-of-blast-radius copy
- **AWS Backup / GCP Backup / Azure Backup** scheduled snapshots of the
  underlying EBS/PD/Managed Disk

For an on-prem real deployment, the simplest pattern is: MinIO local +
nightly `mc cp` mirror to a NAS or a remote MinIO cluster, plus a tape
archive for compliance retention.

## Disaster scenarios

| Failure | Recovery path | Required artifacts |
|---|---|---|
| Keycloak pod crashes | K8s scheduler restarts it; data is on the Postgres PVC | none |
| Postgres primary pod crashes | CNPG promotes the replica (Cluster has `instances: 2`) | none |
| Postgres data corrupted | Restore from MinIO via the PITR procedure above | `cnpg-backup-minio-creds` Secret accessible in cluster |
| Vault sealed (pod restart) | Re-run `init-vault.{ps1,sh}` — detects already-initialized, unseals only | `terraform/vault-keys.json` |
| Vault data lost (PVC gone) | Restore Raft snapshot procedure above | `vault.snap` from MinIO + `vault-keys.json` |
| Entire VM destroyed | Rebuild via `bootstrap.ps1`, restore Postgres + Vault from MinIO | MinIO data preserved AND keys |
| **MinIO PVC corrupted/lost** | **Backups gone. No recovery in the lab.** | — (production: secondary region MinIO) |

# Production Gaps — what I would change

This document captures the gap between what this lab ships and the
production-grade deployment. Each section names the
trade-off explicitly so a reviewer can see where the lab/prod line was drawn
and why.

---

## Infrastructure pipeline — Vagrant is the PoC, not the production path

The current implementation using **Vagrant + VirtualBox** is strictly an
isolated local **Desktop Proof of Concept (PoC)**. It keeps the reviewer
flow to one command and zero cloud dependencies, but it is not how this
platform would be provisioned in production.

Production pivots to a modular, multi-tool pipeline that decouples
**infrastructure provisioning** from **software configuration**:

```
[ Terraform ] ─► [ cloud-init ] ─► [ Ansible ] ─► [ GitOps / ArgoCD ]
 Enterprise VMs   First-boot OS    OS harden +     Workloads +
 + networks       + SSH + net      RKE2 multi-node Longhorn config +
                                   bootstrap       S3 backup targets
```

- **Infrastructure (Terraform/Pulumi).** The IaC layer stays — only its
  **provider** changes. Vagrant/VirtualBox swaps out for an enterprise
  hypervisor or cloud integration: **VMware vSphere**, **SUSE Harvester**
  (HCI built on Kubernetes), **Proxmox**, **Metal³** / **Tinkerbell** for
  bare-metal lifecycle, or public-cloud APIs (AWS / GCP / Azure / OCI /
  sovereign-cloud equivalents). Variables like `ha_mode`,
  `control_plane_count`, `worker_count`, `disk_class` become first-class
  inputs.
- **Operating system (cloud-init).** Runs at first boot to inject
  production network config, SSH keys, hostname, NTP, and the basic
  prerequisites Ansible expects (`open-iscsi` for Longhorn, kernel
  modules, swap off, br_netfilter loaded).
- **Cluster bootstrap (Ansible).** Validates production OS requirements
  and coordinates the multi-node RKE2 sequence: initialize control-plane
  node 1, extract the secure cluster token, programmatically join
  control-plane nodes 2-3 and worker nodes, configure the external load
  balancer.
- **Workloads (GitOps).** The existing `argocd/` + `charts/` +
  `manifests/` tree from this repo applies unchanged.

### Production deployment rules

- **Control-plane isolation.** Three (3) dedicated control-plane nodes
  running etcd + apiserver + controller-manager + scheduler exclusively.
  Tainted `node-role.kubernetes.io/control-plane=:NoSchedule`. No
  application workloads on control-plane nodes — etcd is latency-sensitive
  and noisy neighbours blow apiserver SLOs.
- **External load balancer.** Independent HAProxy + keepalived (on 2 LB
  VMs for VRRP failover), hardware LB (F5 / A10), or a cloud-native
  NLB in front of the three apiservers on port 6443 + the RKE2
  registration port 9345.
- **Disk isolation for storage.** Worker nodes get **dedicated raw
  SSDs/NVMe** for Longhorn, fully separated from the OS boot drive.
  Mixing application I/O with the OS disk is a hot-spot anti-pattern at
  load.
- **Topology spread.** Each control-plane VM lands in a different fault
  domain — different ESXi host (vSphere), different rack (bare metal),
  different AZ (cloud).

Full topology, sequencing, and `ha_mode` flag design is in
[`ha-pattern.md`](ha-pattern.md).

---

## ArgoCD — HA configuration

In this lab ArgoCD runs with single replicas because the cluster has one node.

On the multi-node production cluster (3 RKE2 servers + N workers, or a real managed K8s), the Helm `values` block I would use:

```yaml
# HA without autoscaling - production
redis-ha:
  enabled: true              # 3-node Sentinel-fronted redis cluster
controller:
  replicas: 1                # leader-elected; multi-replica requires sharding
server:
  replicas: 2
repoServer:
  replicas: 2
applicationSet:
  replicas: 2
```

Notes for true HA:
- `controller` stays at 1 unless application-controller sharding is configured
  (`--app-resync` + `ARGOCD_CONTROLLER_REPLICAS`). Two unsharded controllers
  cause leader-election thrash.
- `server`/`repoServer`/`applicationSet` scale horizontally - 2 replicas
  survives a single node/pod failure.
- Soft anti-affinity (`preferredDuringScheduling...`) is set by the chart by
  default for these, so they spread across nodes when possible.

For higher load, add the autoscaling block:

```yaml
controller:
  metrics:
    enabled: true
server:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 5
repoServer:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 5
```

---

## Host OS — SLE Micro / openSUSE MicroOS

This lab runs **openSUSE Leap 15.6** because it integrates cleanly with the
`vagrant up`/`vagrant provision` iteration loop. The vendor-aligned production
host is **SLE Micro** (or the free community equivalent **openSUSE MicroOS**):

- Immutable root filesystem (`/usr` read-only)
- Transactional updates with btrfs snapshots and automatic rollback
- Ignition + Combustion declarative bootstrap
- Designed specifically as a container host

On a real production cluster I would manage these via **Rancher Elemental** -
declarative OS lifecycle driven from Kubernetes (`MachineRegistration` and
`Machine` CRs).

---

## Vault config — Terraform provider for declarative state

The lab uses `scripts/ps/init-vault.ps1` for the entire Vault bootstrap. The
script handles two distinct classes of operation:

1. **Imperative bootstrap** — `vault operator init`, `vault operator unseal`,
   persisting unseal keys. The **official Vault Terraform provider**
   (`hashicorp/vault`) can't do these steps because the provider requires
   an authenticated client, and pre-init there's no auth backend / token
   to talk to. Terraform as a whole *can* drive this via
   `null_resource` + `local-exec` shelling out to `vault operator init`
   (which is what we chose to keep in `scripts/ps/init-vault.ps1` for
   process clarity — it's not a hard limitation of the tool). In
   production this step is **replaced by auto-unseal** via cloud KMS /
   HSM, so the imperative-bootstrap problem disappears entirely.

2. **Declarative configuration** — enable auth methods, enable secrets
   engines, write policies, create roles, seed initial KV paths. **This is
   what should move to Terraform in production.**

Production split:

```
scripts/init-vault.{ps1,sh}  →  init + unseal + persist root keys
                                (one-time bootstrap, run once after Vault
                                 reaches the unseal stage)
terraform apply              →  Vault Terraform provider declaratively
                                manages auth methods, mounts, policies,
                                roles, and seed secrets
```

Implementation sketch:

```hcl
provider "vault" {
  address = "https://vault.lab.test"
  token   = jsondecode(file("../vault-keys.json")).root_token
}

resource "vault_auth_backend" "k8s" {
  type = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "this" {
  backend            = vault_auth_backend.k8s.path
  kubernetes_host    = "https://kubernetes.default.svc:443"
}

resource "vault_mount" "kv" {
  path    = "secret"
  type    = "kv-v2"
  options = { version = "2" }
}

resource "vault_policy" "eso_secret_reader" {
  name   = "eso-secret-reader"
  policy = file("${path.module}/policies/eso-secret-reader.hcl")
}

resource "vault_kubernetes_auth_backend_role" "eso" {
  backend                          = vault_auth_backend.k8s.path
  role_name                        = "external-secrets"
  bound_service_account_names      = ["external-secrets"]
  bound_service_account_namespaces = ["external-secrets"]
  token_policies                   = [vault_policy.eso_secret_reader.name]
  token_ttl                        = 86400
}

resource "random_password" "minio_admin" {
  length  = 32
  special = false
  lifecycle { ignore_changes = [length, special, override_special] }
}

resource "vault_kv_secret_v2" "minio_admin" {
  mount = vault_mount.kv.path
  name  = "minio/admin"
  data_json = jsonencode({
    user     = "minio-admin"
    password = random_password.minio_admin.result
  })
}
```

### Why this is the production answer

| Capability | Bash/PS script | Vault Terraform provider |
|---|---|---|
| Declarative | No | Yes |
| Drift detection | No | `terraform plan` shows it |
| Reviewable in `.tf` alongside cluster | No | Yes |
| Auto-rotates passwords | No (script is idempotent — skips existing) | With `random_password` + ignore_changes, same behavior; remove ignore_changes to rotate |
| State persistence | Secrets only in Vault | Secrets in Vault **and** Terraform state |

### Why it's not in this lab

- Adds a second `terraform apply` step in the reviewer flow (Vault has to be init+unsealed by the script first; Terraform can connect only after)
- Vault root token + seeded passwords land in Terraform state. State stays local (`.gitignored`) but it's one more file holding secret material
- ~1-2 hours of HCL + testing for a benefit that doesn't change what the reviewer actually evaluates

For a real production deployment I'd implement it on day one. For a 1-2 day assiment, the script is the way to go.

---

## Vault — HA mode

This lab runs Vault with **Raft storage, single replica, manual unseal**. The
production deployment will include:

- **3-node Raft cluster** with peer auto-join
- **KMS auto-unseal** (AWS KMS, GCP KMS, or Azure Key Vault depending on
  sovereign-cloud constraints)
- **Hardware Security Module (HSM)** for the seal/unseal key on regulated
  workloads
- **Audit log** to a separate persistence layer (not the same disk as the
  storage backend)
- **NetworkPolicy** restricting which namespaces' service accounts can hit
  Vault's auth method

---

## Secrets — ExternalSecrets vs sealed-secrets

This lab uses **External Secrets Operator (ESO)** with the K8s auth method
against Vault. Production trade-off:

| Aspect | ESO + Vault | Sealed-Secrets |
|---|---|---|
| Secret material in Git | Never | Encrypted-only |
| Rotation | Vault re-issues, ESO repulls | Re-encrypt + commit |
| Multi-cluster | Easy (Vault is the source) | Per-cluster keypair |
| Audit trail | Vault audit log | Git history |
| Failure mode | ESO down = stale secrets in cluster | Sealed-secret controller down = new secrets cannot decrypt |

Both are valid. I would lead with ESO because Vault is already in
the stack and the audit trail centralizes well, but for smaller teams or
GitOps-only shops sealed-secrets is a defensible simpler choice.

---

## Wrapper charts — publish to an OCI registry, don't reference paths in Git

This lab references wrapper charts by repo path (`spec.source.path: charts/minio`)
because the chart only matters to this single project. In production:

- **Wrapper charts get versioned and published to an OCI registry**
  (Harbor, GHCR, ECR Public, Artifactory) alongside application images
- **ArgoCD Applications reference the OCI chart by tag**, not by Git path:
  ```yaml
  source:
    repoURL: oci://harbor.company.internal/charts
    chart: minio-wrapper
    targetRevision: 1.4.2
  ```
- Same flow for upstream charts vendored by an internal team (Bitnami fork,
  internal MLflow chart) — they live in the OCI registry, not as bare `.tgz`
  inside an Application repo
- **Reproducibility comes from the chart digest**, not from `.tgz` files
  shipped in Git.

What this gains you:
- No vendored `.tgz` blobs in Git (the `charts/minio/charts/minio-17.0.21.tgz`
  in this lab would be replaced by a digest in the Application spec)
- Charts versioned independently of the apps that consume them
- Same artifact lifecycle as container images — signing (cosign), scanning
  (trivy), promotion through environments
- Helm dependency resolution doesn't need to reach out to external repos at
  ArgoCD sync time — everything pulls from one internal registry

For sovereign-cloud positioning, the registry stays inside the UAE
(Harbor on the same K8s cluster fabric, or a hosted Artifactory under sovereign
contract). External repos like `charts.bitnami.com` are not viable as a
runtime dependency for production gov workloads.

---

## MinIO console SSO — oauth2-proxy + Keycloak OIDC

In this lab the MinIO console (`https://minio.lab.test`) exposes its native
auth — log in with the root credentials from `secret/minio/admin` in Vault.

For production , the console would sit behind an `oauth2-proxy`
sidecar/Ingress that fronts Keycloak OIDC.

```
Browser → Traefik Ingress (oauth2-proxy)
            ↓ unauthenticated → 302 to keycloak.lab.test
            ↓ Keycloak OIDC flow → token cookie
            ↓ authenticated      → upstream: MinIO console (port 9001)
```

Implementation sketch:
- Add `oauth2-proxy` Helm subchart to the MinIO wrapper chart
- Configure with `provider: keycloak-oidc`, `oidc-issuer-url:
  https://keycloak.lab.test/realms/<realm>`, `upstream:
  http://minio.minio.svc:9001`, `redirect-url: https://minio.lab.test/oauth2/callback`
- Add an ExternalSecret pulling `secret/minio/oauth2-client-secret` and
  `secret/minio/oauth2-cookie-secret` from Vault
- Point the MinIO console Ingress at the oauth2-proxy service instead of the
  MinIO service directly
- Keep the MinIO root creds as a break-glass — never use them day-to-day

Skipped in this lab because (1) Keycloak is the assessment subject,
not its consumer, (2) wiring SSO across services is its own multi-hour
exercise, (3) the security gap is well-understood and not implementing it isn't ignorance, it's scope.

---

## TLS — real certificate providers, not self-signed

This lab uses **cert-manager with a self-signed lab CA**. The bootstrap pattern:

1. A `selfsigned-bootstrap` ClusterIssuer mints a long-lived root CA into a Secret
2. A `lab-ca-issuer` ClusterIssuer (type CA, referencing that Secret) signs all app certs

This is intentional for a closed lab — reviewer adds the lab CA cert to their
browser trust store once and every `https://*.lab.test` URL is trusted.

For production, we swap the issuer for a real cert provider:

| Provider | When | ClusterIssuer kind |
|---|---|---|
| **Let's Encrypt** (ACME HTTP-01 or DNS-01) | Internet-facing services with public DNS | `acme` |
| **Let's Encrypt Staging** (ACME staging) | CI tests / pre-prod | `acme` |
| **Private ACME server** (smallstep, step-ca) | Internal services in regulated/sovereign environments where Let's Encrypt isn't acceptable | `acme` |
| **HashiCorp Vault PKI** | Tight integration with the existing Vault deployment | `vault` |
| **AWS Private CA / GCP CAS** | Cloud-native private PKI | external-issuer projects |

For sovereign data positioning, the right answer is most likely
**Vault PKI** (the cert provider runs in the cluster, fully owned by the org, no
external dependency) or a **private ACME** server.

Switching is a one-file change: replace the `lab-ca-issuer` ClusterIssuer
manifest with the appropriate kind. App `Certificate` resources stay
identical — they reference the issuer by name.

---

## Ingress controller — Gateway API path

This lab uses **Traefik** (installed via ArgoCD) because it is actively
maintained, supports both Ingress v1 and Gateway API, and avoids the
**ingress-nginx retirement** (project officially retired
[2025-11-11](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)).

For production the forward-looking choices are:

- **Envoy Gateway** — Gateway-API-native
- **Cilium** — eBPF-based, replaces both CNI and ingress, NetworkPolicy and
  observability in the same component
- **NGINX Gateway Fabric** (F5's Gateway API impl) — if NGINX is the org's
  standard

Notably **not** `kubernetes/ingress-nginx`. Carrying a retired ingress into a
new deployment is technical debt by day one.

---

## Load-balancer — MetalLB BGP mode (or cloud-native LB)

This lab uses **MetalLB in L2 (ARP) mode** because the VirtualBox host-only
network has no BGP-capable upstream router. L2 mode works fine but has one
inherent limitation: each LB IP is "owned" by a single node at a time, so
multi-node load distribution doesn't happen at the LB layer (kube-proxy still
distributes across pod replicas after the packet arrives).

For production the upgrades by deployment shape:

| Deployment | Recommended LB |
|---|---|
| **On-prem with BGP-capable network** | MetalLB in BGP mode — peer with the data center's spine routers, advertise LB IPs as `/32`s, get ECMP load distribution across all speaker nodes |
| **On-prem without BGP** | MetalLB L2 with multiple speakers spread across nodes (failover takes seconds via gratuitous ARP) |
| **On-prem with hardware LB** (F5, A10, Citrix ADC) | `loadBalancerClass` field on Services pointing at the F5 controller — no MetalLB needed |
| **Cloud (AWS/GCP/Azure)** | Use the cloud-native LB (creates an ELB/NLB/Load Balancer automatically) |

---

## Cluster — HA RKE2 (or real managed K8s)

This lab is single-node RKE2. for Production:

- **3 RKE2 server nodes** with embedded etcd (built-in HA)
- **N workload nodes** (taints/tolerations to separate stateful vs stateless
  workloads, gpu nodes, operations, monitoring and any other controls)
- **External load balancer** in front of the API server (HAProxy or hardware)
- **Pod Disruption Budgets** on stateful workloads so the operator's rolling
  ops don't take more than `maxUnavailable` pods down at once
- **Topology spread constraints** on critical Deployments so replicas land in
  different node failure domains

---

## Backup — off-cluster replication + scheduled restore drill

This lab backs up to a **local MinIO** running in the same cluster. for Production:

- **Off-cluster object storage** for the canonical backup (different failure
  domain from the cluster itself). Same-cluster MinIO survives a single
  cluster failure but not a regional outage.
- **MinIO bucket replication** to a second region (or to a different cloud
  provider's S3-compatible store for regulatory diversity).
- **Encryption at rest** with KMS-backed keys.
- **Scheduled restore drill** - a CronJob that restores the latest backup to
  an ephemeral namespace, runs validation queries, then deletes itself. An
  untested backup is a hope, not a backup.

---

## Other gaps worth naming

- **Image signing** with cosign / Notary v2 + Kyverno verification
  policies (`verifyImages` rule). The lab pulls unsigned images from
  public registries; production blocks pulls that lack a valid signature
  matching the org's KMS-rooted key.
- **Vulnerability scanning at admission** with Trivy-operator or Neuvector,
  failing pulls of images above a configurable CVE severity threshold.
- **Node-level autoscaling.** Out of scope for this single-VM PoC (one
  host, no point), but absolutely a thing in production — on both cloud
  and on-prem. The mechanism differs:
    - **AWS**: Karpenter (fast EC2 provisioning, spot integration,
      bin-packing optimization)
    - **On-prem (vSphere / Harvester / Proxmox / Metal³ / bare metal)**:
      **Cluster API (CAPI) + cluster-autoscaler** with a provider matching
      the substrate (CAPV, CAPH, CAPMOX, Metal³, etc.). cluster-autoscaler
      drives `MachineDeployment` replica counts; the CAPI provider
      creates/destroys VMs via the substrate's API. Slower than Karpenter
      (3-5 min per vSphere VM vs. ~30s for EC2), but the same outcome.
      RKE2 clusters registered with Rancher use this pattern via
      Rancher's Provisioning v2.
    - **Pod-level autoscaling (HPA + KEDA + VPA)** is identical on either
      side and does most of the work in practice.

  See [autoscaling-on-prem.md](autoscaling-on-prem.md) for the full
  breakdown — providers per substrate, CAPI resource shapes, and why
  Karpenter is still AWS-first in 2026.
- **Cost observability** — OpenCost + Grafana dashboards. Tracks
  per-namespace + per-workload cost (CPU/memory/storage) against the
  cluster's nominal cost.
- **Centralized log retention** beyond Loki's filesystem store —
  long-term archival to S3/Glacier via Loki's `object_store` config, or
  ship to a dedicated log platform (Datadog, Splunk, Loki+Mimir tier).
- **Tracing** — OpenTelemetry Collector + Tempo or Jaeger; closes the
  RED-method observability loop alongside metrics (Prometheus) and logs
  (Loki).

---

## Storage pivot — Longhorn (in-cluster) + MinIO (off-cluster)

The lab uses `local-path-provisioner` for stateful volumes and an
**in-cluster MinIO** instance as the S3 target for CNPG WAL backups.
Both choices are PoC affordances. Production pivots to a **dual-strategy**:

### In-cluster: Longhorn replaces local-path

- **Default StorageClass** on every worker node — replaces
  `local-path-provisioner`. Workloads stop being node-bound; PVs
  survive node failures and live-migrate across hosts.
- **3-way replication** (configurable) for stateful workloads (CNPG
  Postgres, Vault Raft, Keycloak attachments). Loss of any single
  worker doesn't lose data.
- **Dedicated raw SSDs/NVMe per worker** — Longhorn's `disks` config
  points at a separate block device, not the OS root filesystem. This
  is the production rule called out in
  [`ha-pattern.md`](ha-pattern.md) under "Disk isolation."
- **VolumeSnapshot CRD** integration — snapshot/restore workflows via
  `volsync` or Longhorn's own UI/CRDs.
- **Backups stream to external MinIO** — Longhorn's `BackupTarget` CR
  points at the off-cluster MinIO endpoint; volume backups are
  incremental and run on a schedule per `RecurringJob`.

### Off-cluster: MinIO moves out of the cluster

In the lab, MinIO is a Pod in the `minio` namespace with a local-path
PVC. That's a same-failure-domain anti-pattern: the cluster that
produced the backups is also the cluster that holds them. Production:

- **MinIO runs on dedicated VMs (or hardware) outside the cluster** —
  separate failure domain. A regional outage that takes the cluster
  down doesn't take the backups down.
- **Two MinIO sites with bucket replication** for regulatory diversity
  (`mc replicate` between sites, or active-active multi-site).
- **Three independent backup streams flow into it:**
  - **RKE2 etcd snapshots** — RKE2 has a built-in `etcd-s3-*` config
    that streams snapshots directly to S3. Cluster recovery from a
    complete control-plane loss reduces to "spin up new VMs, point
    them at the snapshot."
  - **Longhorn volume backups** — incremental backups of every
    Longhorn PV, on a per-workload schedule.
  - **CNPG `barmanObjectStore`** — base + WAL backups (unchanged from
    the lab; only the endpoint URL flips from in-cluster to external).
- **Encryption at rest** with KMS-backed keys.
- **Scheduled restore drill** — a
  CronJob that restores the latest backup to an ephemeral namespace,
  runs validation queries, and deletes itself. An untested backup is
  a hope, not a backup.

### Why this is two systems, not one

Longhorn handles **operational** storage — live volumes with
replication for high-availability under normal cluster operation.
External MinIO handles **disaster** storage — point-in-time captures
that survive the cluster they came from. Conflating the two (e.g.
"just put MinIO on Longhorn") couples the disaster recovery target to
the system you might need to disaster-recover.

### Replicated block storage — substrate options

Whichever substrate the cluster runs on, the in-cluster storage layer
depends on what's underneath:

| Substrate | Storage layer | Why |
|---|---|---|
| **On-prem bare metal / VMs** | **Longhorn** (Rancher's, integrates with RKE2 + Rancher Manager) | First-party for Rancher stack, simpler than Ceph for a focused workload set |
| **On-prem at scale** | **Rook + Ceph** | Beyond ~10 nodes Longhorn's manager pod count grows; Ceph scales further. Steeper learning curve. |
| **AWS** | **EBS-CSI** for block, **EFS-CSI** for RWX, **S3 CSI** for static datasets | Cloud-native, snapshots integrate with AWS Backup, no in-cluster storage layer to operate |
| **GCP** | **Filestore-CSI** + **GCE PD CSI** | Same story |
| **Azure** | **Azure Disk CSI** + **Azure Files CSI** | Same |

Whichever it is, the wrapper-chart pattern from the lab carries over:
- Each consumer (Keycloak Postgres, Vault, MinIO if not the backup target) gets
  an `accessModes: [ReadWriteOnce]` + the appropriate `storageClassName`
- VolumeSnapshot CRD enables snapshot/restore workflows via `volsync` or
  the cloud provider's snapshot policy
- Off-cluster S3 backup is independent of the storage layer — CNPG's
  barmanObjectStore still handles DB-level WAL backup regardless of where
  the underlying PV lives

**What the lab demonstrates without it**: CNPG's WAL + base backups to MinIO
cover the data layer that actually matters for Keycloak. PV-level snapshots
are an additional layer for fast clone/rollback, not a replacement for
DB-aware backup.

---

## Logs — Grafana Alloy replaces Promtail

The lab uses Promtail because it's the canonical pairing with Loki. **Grafana Labs deprecated Promtail in
favour of Grafana Alloy in 2026** (Alloy unifies log collection, metric
scraping, and trace collection in one agent based on the OpenTelemetry
Collector).

The migration is straightforward:
- Same DaemonSet shape, same hostPath mount for `/var/log/pods`
- Alloy config file (HCL-like) replaces Promtail's YAML scrape config
- Grafana provides a Promtail-to-Alloy conversion tool
- Both push to the same Loki API (`/loki/api/v1/push`)

Production would deploy Alloy directly rather than carry Promtail config
into a project meant to last 3+ years. Alloy also offers tracing + metric
collection in the same agent — fewer DaemonSets to operate.

---

## MinIO user provisioning — our own idempotent Job

The Bitnami `minio` chart's `provisioning` Job is a Helm hook
(`post-install,post-upgrade` + `hook-delete-policy: hook-succeeded`). On a
fresh install it works. On an incremental upgrade that adds entries to
`usersExistingSecrets`, ArgoCD doesn't trigger a new sync (the chart diff
isn't detected as a sync requirement) and the hook never re-runs. New users
silently fail to materialize in MinIO — the consuming app fails with
`InvalidAccessKeyId`.

**Production answer**: Replace `provisioning` with a Kubernetes Job we own:
- Lives in `charts/minio/templates/provisioning-job.yaml` (not a Helm hook)
- ArgoCD applies it like any other resource, re-applies on every sync
- The Job body uses `mc admin user info $u || mc admin user add $u $pw` —
  idempotent by construction
- Same for `mc admin policy create` (check + create) and
  `mc admin policy attach` (idempotent)
- Adding a new user = update values → Argo sync → Job re-runs → new user
  added, existing users unchanged


---

## Observability stack — built, disabled in the PoC

The full monitoring stack is **built and version-pinned** in this repo:

```
charts/monitoring/
├── Chart.yaml                          # wrapper, three subchart deps
├── values.yaml                         # kube-prometheus-stack + Loki + Promtail config
├── templates/
│   ├── eso-grafana-admin.yaml          # ExternalSecret pulling admin from Vault
│   ├── grafana-datasource-loki.yaml    # Loki datasource ConfigMap (sidecar auto-import)
│   ├── ingress.yaml                    # Traefik Ingress + TLS for grafana.lab.test
│   └── networkpolicy.yaml              # default-deny + scrape-target allow-list
```

Versions pinned: `kube-prometheus-stack` 85.3.3, `loki` 7.0.0 (SingleBinary),
`promtail` 6.17.1. NetworkPolicies allow Prometheus scraping kubelet,
apiserver, node-exporter, kube-state-metrics, Loki, Grafana, Alertmanager —
the full path is wired.

### Why it ships disabled

The Application file is renamed to `argocd/apps/monitoring.yaml.disabled`
so ArgoCD's directory recursion skips it (it only picks `.yaml` /
`.yml`). On a single-VM 8 vCPU / 12 GB PoC the stack is the difference
between a working cluster and a thrashing one:

- **Promtail DaemonSet** holds 50-60% of a CPU steady tailing
  `/var/log/pods` and pushing to Loki. On 8 vCPU that's nearly an entire
  core dedicated to log shipping for a cluster nobody is querying.
- **Prometheus + kube-state-metrics + node-exporter + Loki**
  collectively add ~1.5-2 GB working set and another 0.5-1 vCPU steady.
- Under the combined load, kube-scheduler and kube-controller-manager
  static pods miss their liveness probes (kubelet probe timeout is 1s),
  get killed, and crashloop. That cascades — every controller (Argo,
  ESO, cert-manager, CNPG, Keycloak operator) re-lists its watches when
  apiserver restarts, which loads apiserver further. The cluster never
  reaches steady state.

The fix is more vCPU — not removing the stack. A single-VM PoC simply
doesn't have the headroom. Production doesn't hit this because workers
sit on dedicated hardware/VMs with multi-core budgets per workload and
the monitoring tier typically gets its own node pool (taint:
`workload=monitoring:NoSchedule`).

### How to re-enable

On a host with ≥12 vCPU / ≥16 GB allocated to the VM:

```bash
# rename back
git mv argocd/apps/monitoring.yaml.disabled argocd/apps/monitoring.yaml
git commit -m "enable monitoring stack"
git push

# argocd self-heals into the desired state within a sync cycle (~3 min)
```

No code or values change needed — the chart, ESO bindings, Ingress, and
NetworkPolicies are all in `charts/monitoring/`, ready to deploy.

### Production posture

On a multi-node production cluster, the observability stack is part of
the baseline platform — not optional:

- **Dedicated monitoring node pool.** Workers labeled
  `workload=monitoring` + taint, so Prometheus / Loki / Grafana / agents
  schedule there and never compete with application workloads for CPU
  or memory.
- **Long-term metric retention** via `remote_write` to Thanos / Mimir /
  a managed Prometheus service. The lab's 24h retention is a
  PVC-bounded compromise that won't fly in prod.
- **Loki S3 backend, not filesystem.** The lab's 5 GiB filesystem PVC is
  for a single binary; production uses Loki's scalable mode against S3.
- **Promtail → Alloy migration.** Covered in the "Logs" section below.
- **Alertmanager enabled** with PagerDuty / Slack / Opsgenie webhooks
  (the lab disables it because there's no on-call to page).

The `charts/monitoring/values.yaml` in this repo is the *minimum viable
config* for the PoC's footprint. Production values would scale every
retention + replica + resource knob upward, but the **wiring** — wrapper
chart, ESO secret bindings, NetworkPolicies for scrape paths, Ingress
behind Traefik — stays identical.

---

## Metrics — app-level scraping via ServiceMonitor + NetworkPolicy

The lab scrapes **cluster-level metrics only**: node-exporter (host CPU/
RAM/disk/network), kube-state-metrics (K8s object inventory), kubelet
cAdvisor (per-pod CPU/memory/network). That covers ~80% of useful
dashboards out of the box.

App-level metrics (Keycloak, CNPG postgres-exporter, MinIO Prometheus
endpoint, Vault Prometheus endpoint, cert-manager metrics, ESO metrics)
need two changes per workload:

1. **ServiceMonitor CR** in the workload's namespace pointing at its
   `/metrics` endpoint. The Prometheus operator already watches
   ServiceMonitors cluster-wide (`serviceMonitorSelectorNilUsesHelmValues:
   false`), so dropping a ServiceMonitor in any namespace gets it scraped
   automatically.

2. **NetworkPolicy ingress allow** on the target pod for the metrics port,
   from the `monitoring` namespace. Required because the lab's default-
   deny stance blocks Prometheus's egress otherwise.

Production deployment would add ServiceMonitor + NetworkPolicy templates to
each wrapper chart so every workload's metrics flow into Prometheus
automatically. The Keycloak ServiceMonitor in particular would scrape login
success/failure rates, session counts, and event API hits — the kind of
metrics SRE teams alert on.

---

## OIDC SSO — Keycloak as identity provider for everything else

The lab uses separate static credentials for ArgoCD, MinIO Console, Vault,
and Grafana. Production deployment would wire each behind Keycloak OIDC:

- **ArgoCD**: native OIDC config (`dex.config` block in the Helm values)
  or direct OIDC via `oidc.config`. Group claim mapping to RBAC roles.
- **Grafana**: `auth.generic_oauth` block ( 
  `kube-prometheus-stack` wrapper for a complete reference, including
  split-horizon URLs for browser vs in-cluster traffic).
- **MinIO Console**: OIDC via the `MINIO_IDENTITY_OPENID_*` env vars OR
  oauth2-proxy in front of the Ingress.
- **Vault**: OIDC auth method (`vault auth enable oidc` + role mapping).

The pattern: each app's OIDC client lives in Keycloak's `master` realm (or
a dedicated platform realm), client secret materialized into the app's
namespace via ESO, group → role mapping in the app's config. Removes every
static admin password from operational rotation.

Lab deferred to keep the "Keycloak as the assessment headline" scope
contained. Demonstrating one OIDC client end-to-end (e.g. Grafana → Keycloak)
would be a strong follow-up exercise.

---

## ArgoCD sync retry — `retry.limit: 20` as the default

This is implemented in the lab as a cross-cutting decision — every Application has explicit retry config. Documenting
here as a **must-have for any production cluster** because the default
ArgoCD behaviour (selfHeal but no failed-sync retry) leads to a fragile
bootstrap experience.

Production cluster patterns:
- **AppProject-level default**: set retry policy at the AppProject so every
  Application in the project inherits it. Removes the per-Application
  boilerplate. Requires running ArgoCD 2.x+.
- **Higher retry limit for slow-to-Ready CRDs**: cert-manager, Istio, ESO,
  Prometheus operator all install CRDs + webhooks where the first sync
  can fail until the webhook endpoint is ready. `limit: 20` with 5m
  backoff handles this comfortably.
- **AppSet-driven fleet management**: ApplicationSet generator with a
  Cluster generator + Helm parameter templating reconciles N tenant clusters
  from a single source. Production teams of platform engineers run this.

---
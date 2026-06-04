# iac-rke2-keycloak

> Reproducible deployment of Keycloak
> on a local single-node RKE2 cluster, provisioned with Terraform + Vagrant and
> reconciled end-to-end with ArgoCD. CloudNativePG-backed Postgres with continuous
> backup to MinIO. Vault-managed secrets via External Secrets Operator. TLS
> via cert-manager. Pod Security restricted + NetworkPolicy-based hardening.

## Assignment summary

This repository is my submission for DevOps assessment. The brief was: **deploy a fully functional Keycloak on a local Kubernetes cluster, fully automated and reproducible via IaC, with HTTPS access, admin account, and basic network hardening. Pulumi+Go is a bonus.** What's here delivers that plus the production engineering around it:

| Requirement | How it's covered |
|---|---|
| Local K8s cluster (Rancher preferred) | **RKE2** — Rancher's distribution |
| Fully automated IaC | One-command bootstrap; idempotent re-runs |
| IaC tool — Pulumi+Go (**bonus**) | **Both** Terraform and Pulumi+Go paths, validated end-to-end |
| Keycloak with admin account | `bootstrapAdmin` materialized from Vault into a K8s Secret; credentials retrievable via `kubectl` (see [Keycloak login credentials](#credentials)) |
| HTTPS access | cert-manager + `lab-ca-issuer` + Traefik TLS at `https://keycloak.lab.test` |
| Basic network hardening | Restricted PSS on the keycloak namespace + default-deny NetworkPolicies in every workload namespace + per-app allow-listed pinholes |

**Beyond the brief:** Vault + ESO (no plaintext secrets in Git), CNPG operator (HA primary + replica + WAL backups to MinIO), Vault Raft snapshot CronJob (Phase 11), ArgoCD app-of-apps with sync waves + retry config, six design docs covering architecture, decisions, production gaps, HA pattern, backup/recovery, and Pulumi mirror.

## Assumptions and constraints

- **Single host.** The PoC runs on one host machine with VirtualBox. No remote infrastructure is assumed; no cloud account required.
- **One IaC path per session.** Both Terraform and Pulumi target the same VirtualBox VM name (`rke2-server-1`) and host-only IP (`192.168.56.10`). Running both at once collides — pick one, then teardown before switching.
- **Clone path must not contain spaces.** The Terraform `kubectl apply -f <path>` step uses minimal shell quoting. Stick to `C:\Users\<name>\projects\iac-rke2-keycloak` (no `OneDrive` / `Program Files` paths).
- **Windows 11: Hyper-V must be off.** VirtualBox can't run while Hyper-V is enabled. WSL2 + Docker Desktop both depend on Hyper-V — disabling it disables them too. See [Prerequisites](#prerequisites) for the toggle commands.
- **Validated platforms.** The **PowerShell** wrappers were exercised end-to-end on Windows 11 / PowerShell 5.1 for both IaC paths. The **bash** siblings mirror the PowerShell logic line-for-line but were not run end-to-end during the assessment — a Linux/macOS reviewer is the first to validate.
- **Hosts file entry required.** Apps are served from `https://<name>.lab.test` behind the MetalLB IP `192.168.56.20`. Add the hosts entry shown under [Hosts file](#hosts-file--required-for-labtest-urls) before opening any URL.
- **Self-signed lab CA.** Certificates are signed by an in-cluster CA. Browsers will warn until you add the lab CA to your trust store (one-time, optional — see [Trust the lab CA](#trust-the-lab-ca-optional--eliminates-browser-warnings)). Production swaps the lab CA for a real ACME / Vault PKI issuer in one file.
- **Monitoring stack built but disabled in the PoC.** Prometheus + Grafana + Loki + Promtail are wired in `charts/monitoring/` but `argocd/apps/monitoring.yaml.disabled` is gated off — the single-VM footprint can't run them alongside the rest without CPU starvation. Rename to `.yaml` to enable on a host with ≥12 vCPU / ≥16 GB. Production has no such constraint — see [docs/production-gaps.md](docs/production-gaps.md).
- **Vault uses imperative bootstrap.** `init-vault.{ps1,sh}` runs `vault operator init` / `unseal` / policy + role writes. Vault Helm provider can't do init (no auth pre-init); production replaces this with auto-unseal via cloud KMS + the Vault Terraform provider for declarative config. See [Design choices](#design-choices) → Vault bootstrap, and [docs/production-gaps.md](docs/production-gaps.md).
- **PoC scope, not HA.** Single VM, single Vault Raft replica, single Keycloak instance. The HA pivot (3 control-plane + N workers + external LB + Longhorn + off-cluster MinIO + KMS auto-unseal) is documented in [docs/ha-pattern.md](docs/ha-pattern.md).

## TL;DR — Run it

**Pick ONE IaC path per session** (both target the same VirtualBox VM + IP — running both at once collides). Both reach the same Healthy cluster.

> Before running either script, confirm you have the tools installed — see [Prerequisites](#prerequisites) for the full per-OS install commands.

> **Tested platforms.** The **PowerShell** wrappers (`bootstrap.ps1`, `bootstrap-pulumi.ps1`, `init-vault.ps1`) were exercised end-to-end on Windows 11 / PowerShell 5.1 for both the Terraform and Pulumi paths. The **bash** siblings (`bootstrap.sh`, `bootstrap-pulumi.sh`, `init-vault.sh`) mirror the PowerShell logic line-for-line and are provided for Linux / macOS reviewers, but were **not** executed end-to-end during the assessment. They should work — same `vagrant up` / `terraform apply` / `pulumi up` / `kubectl` commands — but a reviewer using them is the first to validate.

### Path A — Terraform

```powershell
# Windows / PowerShell  (powershell.exe = built-in PS 5.1)
git clone https://github.com/asafwat/iac-rke2-keycloak.git
cd iac-rke2-keycloak
powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap.ps1 -WaitForHealthy
```

```bash
# Linux / macOS
git clone https://github.com/asafwat/iac-rke2-keycloak.git
cd iac-rke2-keycloak
./scripts/bash/bootstrap.sh --wait-for-healthy
```

### Path B — Pulumi + Go

Requires Go 1.22+ and Pulumi 3.140+ on PATH in addition to the Path A prereqs. Design + provider-equivalence table: [docs/pulumi-mirror.md](docs/pulumi-mirror.md).

```powershell
# Windows / PowerShell
git clone https://github.com/asafwat/iac-rke2-keycloak.git
cd iac-rke2-keycloak
$env:PULUMI_CONFIG_PASSPHRASE = 'lab-passphrase-change-me'   # any non-empty string for the lab
powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap-pulumi.ps1 -WaitForHealthy
```

```bash
# Linux / macOS
git clone https://github.com/asafwat/iac-rke2-keycloak.git
cd iac-rke2-keycloak
export PULUMI_CONFIG_PASSPHRASE='lab-passphrase-change-me'
./scripts/bash/bootstrap-pulumi.sh --wait-for-healthy
```

### What either script does

Validates tools on PATH → IaC apply (`terraform apply` for Path A; `pulumi login --local && pulumi up --stack dev` for Path B) → waits for Vault pod → runs `init-vault.{ps1,sh}` to initialize + unseal Vault + seed secrets + create ESO and `vault-snapshot` roles → waits for every Argo Application to reach `Healthy`. End-to-end time on first run: **~25–30 min** (image pulls dominate). Re-runs are idempotent.

> **Keycloak takes longer than the rest.** On a resource-constrained PoC VM, the Keycloak pod is the last workload to materialize and can take **5–10 minutes after the script reports "All Applications Healthy"** before it's actually serving traffic. The script's healthy-check looks at ArgoCD's `Application.status.health` — which the `Keycloak` CR can briefly report as `Healthy` while the operator is still building the StatefulSet, pulling the ~500 MB Keycloak image, running the Quarkus build phase, and applying ~80 schema migrations to Postgres on first start. If `https://keycloak.lab.test` returns 502/504 right after bootstrap, that's normal — watch `kubectl -n keycloak get pods -w` until `keycloak-0` is `Running 1/1`, then try the URL again. Production with more vCPU avoids this entirely.

Then add the hosts entry below and open https://argocd.lab.test, https://keycloak.lab.test, https://grafana.lab.test, …

## Architecture

```
                        Host (your machine)
                              │
                              │  192.168.56.20:443  (MetalLB-advertised IP)
                              ▼
                ┌─────────────────────────────────┐
                │  Vagrant VM (openSUSE Leap 15.6)│
                │  6 vCPU / 10 GB / VirtualBox    │
                │  ┌───────────────────────────┐  │
                │  │ RKE2 single-node          │  │
                │  │                           │  │
                │  │  Traefik (Ingress + TLS)  │  │
                │  │      │                    │  │
                │  │      ▼                    │  │
                │  │  ┌──────────────────────┐ │  │
                │  │  │ ArgoCD (GitOps)      │ │  │
                │  │  │  - root-app          │ │  │
                │  │  │  - ~17 child apps    │ │  │
                │  │  │  - sync waves -4..5  │ │  │
                │  │  └──────────────────────┘ │  │
                │  │                           │  │
                │  │  Keycloak ──► CNPG Postgres─►MinIO (cnpg-backups)
                │  │      ▲              (HA primary+replica + WAL backup)
                │  │      │
                │  │  cert-manager (lab-ca-issuer)
                │  │  MetalLB (L2 advertisement)
                │  │  External Secrets Operator ──► Vault (Raft)
                │  │  Prometheus + Grafana + Loki + Promtail (disabled)
                │  │                           │  │
                │  └───────────────────────────┘  │
                └─────────────────────────────────┘
```

**Key design properties:**
- **Single source of truth = Git.** Terraform/Pulumi installs only ArgoCD and the root Application. Everything else (cert-manager, MetalLB, Traefik, Vault, ESO, MinIO, CNPG, Keycloak, vault-backup, monitoring) is reconciled by ArgoCD from this repo. Full rebuild: `terraform destroy && terraform apply` (Path A) or `pulumi destroy && pulumi up` (Path B).
- **Layered backup.** CNPG `barmanObjectStore` ships base+WAL backups to MinIO continuously (DB-layer PITR). MinIO retains snapshots in scoped buckets per consumer.
- **No plaintext secrets in Git.** Vault is the source of truth; ESO materializes K8s Secrets on demand. The only files written outside Git are `kubeconfig` (Vagrant) and `terraform/vault-keys.json` (init script; gitignored).
- **Self-healing GitOps.** Every Argo Application has `automated.selfHeal: true` plus `retry.limit: 20` with exponential backoff — webhooks-not-ready races resolve automatically without manual sync pokes.
- **Restricted Pod Security on Keycloak.** The keycloak namespace enforces `pod-security.kubernetes.io/enforce: restricted`. Keycloak app pods + operator + CNPG Postgres pods all comply.
- **Default-deny NetworkPolicies** in every workload namespace + explicit allow-listed pinholes (Traefik → backends, ESO → Vault, Prometheus → kubelet/apiserver, etc.).

## Design choices

These are the non-obvious decisions that shaped the architecture. Each one trades a different thing.

### Bootstrap split: IaC for the cluster, GitOps for the workloads

**Decision.** Terraform / Pulumi installs **only ArgoCD and the root Application**. Every other component — cert-manager, MetalLB, Traefik, Vault, ESO, MinIO, CNPG, Keycloak, NetworkPolicies, monitoring — is declared in `argocd/` and `charts/` and reconciled by ArgoCD from this repo.

**Why not "Terraform-all-the-things":**
- **State + lifecycle mismatch.** Terraform's state model assumes static infrastructure; Kubernetes workloads are inherently dynamic (operator-managed pods, autoscalers, controllers reconciling). Terraform fighting controllers over the same resource produces drift the operator considers "normal" and Terraform considers "broken."
- **Pull-mode reconciliation > push-mode apply.** ArgoCD continuously reconciles desired-state against actual-state. Drift detection and self-healing are free. Terraform only acts when you run `apply`.
- **Operational surface area.** A `terraform apply` failure mid-run on 30+ Kubernetes resources is an operational nightmare. ArgoCD's per-Application status, retry/backoff, and prune semantics are purpose-built for this.
- **Audit + review workflow.** A `git push` to `charts/keycloak/values.yaml` is a reviewable PR with full history; a change to a value buried in a Terraform module is harder to spot in code review.

The IaC layer's job is the one thing GitOps can't do for itself: **create the cluster the GitOps tool runs on**.

### Postgres via the CloudNativePG operator, not a Helm-managed Postgres

**Decision.** Keycloak's database is a CNPG `Cluster` resource (operator-managed StatefulSet), not the Postgres subchart of the Bitnami chart or a hand-rolled StatefulSet.

**Why CNPG:**
- **Operator handles the full DB lifecycle:** primary/replica election, failover, rolling upgrades, in-place major-version upgrades, role + user provisioning, backups via `barmanObjectStore`, point-in-time recovery — none of which a Helm chart can do declaratively.
- **CR is the API.** Changing `spec.instances: 2 → 3` triggers a controlled rolling expansion; changing `spec.imageName` to a newer Postgres triggers a rolling upgrade with WAL-consistent failover. Helm `replicaCount` can't do that safely.
- **Backups are first-class.** `Backup` and `ScheduledBackup` CRs are part of the same API as the cluster definition. No separate backup tool.

### Keycloak via the official Keycloak operator, not a community Helm chart

**Decision.** The `Keycloak` CR from the official Keycloak operator (`k8s.keycloak.org/v2alpha1`) — vendored upstream — owns the workload. Our wrapper chart provides the Keycloak CR + Ingress + ExternalSecrets + NetworkPolicies + namespace PSS labels around it.

**Why the official operator:**
- **Vendor-supported upgrade path.** The Keycloak project ships and tests the operator alongside each Keycloak release. Community charts lag behind.
- **Realm import / cluster mode / DB connection are operator-native.** Multi-replica with Infinispan cache, JGroups discovery via headless Service, sticky sessions — the operator wires these correctly. A bare Helm chart doesn't.
- **`unsupported.podTemplate` escape hatch** for security-context overrides (drop ALL caps, runAsNonRoot, seccomp RuntimeDefault) without forking the operator.

### Vault + External Secrets Operator (ESO), not Sealed Secrets or raw `kubectl create secret`

**Decision.** Secrets live in Vault (Raft storage, KV v2 engine at `secret/`). Every K8s Secret is materialized via an `ExternalSecret` CR that ESO resolves against the `ClusterSecretStore: vault`.

**Why this pairing:**
- **Zero secret material in Git.** Even encrypted. Sealed Secrets keeps an encrypted blob in Git; rotation = re-encrypt + commit + push. ESO + Vault: rotate in Vault, ESO repulls.
- **Audit trail in Vault, not Git history.** Vault audit log captures every read; Git history exposes secret rotation timing to anyone with repo access.
- **Authentication via Kubernetes auth method.** ESO talks to Vault using its own pod's ServiceAccount JWT — no static credentials, no manual token plumbing.
- **Centralized for multi-cluster.** Future multi-cluster fleets resolve the same secret paths from the same Vault.

### Vault bootstrap: imperative script in the lab, declarative IaC + auto-unseal in production

**Decision.** Vault is initialized, unsealed, and seeded by `scripts/ps/init-vault.ps1` (and the bash sibling), invoked from the bootstrap wrapper after the `vault-0` pod reaches `Running`. The script:

1. **Initializes** Vault — `vault operator init -key-shares=1 -key-threshold=1` (one Shamir share, lab-grade), persists the unseal key + root token to `terraform/vault-keys.json` (gitignored).
2. **Unseals** Vault using the saved key.
3. **Enables** the KV v2 secrets engine at `secret/` and the Kubernetes auth method.
4. **Writes policies**: `eso-secret-reader` (read on `secret/data/*`) and `vault-snapshot-policy` (read on `sys/storage/raft/snapshot`).
5. **Creates Kubernetes auth roles** binding ServiceAccounts to those policies: `external-secrets` for ESO, `vault-snapshot` for the backup CronJob.
6. **Seeds initial KV paths**: random 32-char passwords for `secret/minio/admin`, `secret/postgres/keycloak`, `secret/keycloak/admin`, `secret/grafana/admin`, plus the scoped MinIO access keys for CNPG and Vault-snapshot backups.

The script is **idempotent** — re-running it detects existing init/policies/roles/secrets and skips them.

**Why this shape is right for a lab and wrong for production:**

| Concern | Lab implementation | Why it's a lab-only shortcut |
|---|---|---|
| **Unseal** | Manual `vault operator unseal` from local-disk key file | Pod restart = sealed Vault until an operator re-runs the script. Not survivable in production. |
| **Init persistence** | `vault-keys.json` on host filesystem, gitignored | Loss of the file = unrecoverable cluster. No HA, no recovery procedure beyond "don't lose it." |
| **Shamir 1/1** | Single share, single threshold | Real production uses 5/3 (5 shares, threshold 3) split between multiple human operators. |
| **Configuration** | Imperative `vault write` / `vault policy write` calls | No drift detection, no reviewable diff, state lives in Vault itself. |

**Production answer — split init from configuration:**

1. **Auto-unseal** via cloud KMS (AWS KMS, GCP KMS, Azure Key Vault) or an HSM (Luna, CloudHSM, YubiHSM). Vault calls the KMS API on startup to decrypt the root key; pod restarts auto-unseal. **The `vault-keys.json` file disappears entirely.** This is what makes Vault HA-viable.
2. **Declarative configuration via the Vault Terraform provider** (`hashicorp/vault`) — auth methods, KV mounts, policies, Kubernetes auth roles, and seed KV paths all become Terraform resources. Drift detection via `terraform plan`. Reviewable diffs in PRs. The provider needs an authenticated client, so it runs *after* the auto-unseal step:

   ```hcl
   resource "vault_auth_backend" "k8s" { type = "kubernetes" }

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
   ```

3. **3-node Raft cluster** with peer auto-join. Single replica in the lab is HA-shaped (`ha.enabled: true`) but not actually HA — Raft needs a quorum.
4. **Audit log** to a separate persistence layer (not the same disk as the storage backend).
5. **NetworkPolicy** restricting which namespaces' ServiceAccounts can hit Vault's auth method.

The **imperative-bootstrap problem disappears** in production because auto-unseal removes the human-in-the-loop step. What stays in a script is "the one-time init" — and even that gets replaced by the auto-unseal mechanism's bootstrap flow for the underlying KMS keys.

Full production posture in [docs/production-gaps.md](docs/production-gaps.md) under "Vault — HA mode" and "Vault config — Terraform provider for declarative state."

### Pod Security Standards `restricted` enforced on the Keycloak namespace

**Decision.** The `keycloak` namespace carries `pod-security.kubernetes.io/enforce: restricted` (PSA enforce mode). Keycloak app pods + Keycloak operator + CNPG Postgres pods all comply.

**Why restricted, not baseline:**
- `restricted` is the strictest standard PSS profile — runAsNonRoot, drop ALL capabilities, allowPrivilegeEscalation: false, RuntimeDefault seccomp, no host namespaces, no privileged containers.
- It catches misconfigurations at admission (`kubectl apply` is rejected) instead of at runtime (probe failures / silent compromises).
- It documents the workload's actual privileges in the namespace itself — a reviewer can see PSS posture without inspecting every pod spec.

Production extends this to every workload namespace; documented in [docs/production-gaps.md](docs/production-gaps.md).

### Default-deny NetworkPolicies, per-app allow-lists written from observed traffic

**Decision.** Every workload namespace ships a `default-deny-all` NetworkPolicy plus explicit allow-listed pinholes (Traefik → backends, ESO → Vault, CNPG → MinIO, Keycloak → Postgres, etc.). Policies are written from **observed traffic**, not guessed.

**Why this order:**
- Cluster boots with no NetworkPolicies (wave 4 is the last to apply) → real traffic patterns emerge under load → policies are written to match exactly that graph.
- Discovery-first means we don't accidentally over-allow (`{}` ingress) or under-allow (forgetting a path).
- Wave-4 ordering also means debugging is easier: cluster is known-good before policies land, so any post-wave-4 break is unambiguously a NetworkPolicy issue.

### Self-signed lab CA via cert-manager, swappable to real PKI in one file

**Decision.** A `selfSigned-bootstrap` Issuer signs the lab CA cert, which becomes the `lab-ca-issuer` ClusterIssuer that signs every workload cert. App `Certificate` resources reference the ClusterIssuer by name.

**Why this shape:**
- One-file production swap: replace the `lab-ca-issuer` ClusterIssuer manifest with `acme` (Let's Encrypt), `vault` (Vault PKI), or any other cert-manager issuer kind. App manifests stay untouched.
- Vault PKI is the production answer for sovereign-data deployments (the issuer runs in-cluster, no external dependency) — `production-gaps.md` covers the swap.

### Traefik for Ingress, not ingress-nginx

**Decision.** Traefik (installed via ArgoCD, version-pinned chart) handles all `*.lab.test` ingress. RKE2's bundled `rke2-ingress-nginx` is explicitly disabled.

**Why not ingress-nginx:**
- The `kubernetes/ingress-nginx` project is officially retired as of [2025-11-11](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/). Carrying a retired ingress into a new deployment is technical debt by day one.
- Traefik supports both Ingress v1 and Gateway API, has active vendor backing, and integrates cleanly with cert-manager via annotations.

### MetalLB L2 mode for LoadBalancer Services

**Decision.** MetalLB in L2 (ARP) mode advertises the `192.168.56.20-29` pool on the host-only network. Traefik's Service is `type: LoadBalancer` and picks up `192.168.56.20`.

**Why L2 (not BGP):**
- The VirtualBox host-only network has no BGP-capable upstream router to peer with — L2 is the only mode that works here.
- Production with a BGP-capable spine would flip `IPAddressPool` + `BGPAdvertisement` and add `BGPPeer` CRs — no other changes needed.

### Layered backup: DB-aware, not just PV snapshots

**Decision.** Two independent backup pipelines run on a daily schedule:
- **CNPG `barmanObjectStore`** ships continuous WAL + nightly base backups to `s3://cnpg-backups/keycloak/` in MinIO.
- **Vault Raft snapshot** CronJob runs at 03:00 (`manifests/vault-backup/cronjob.yaml`), authenticates to Vault via the kubernetes auth method, and uploads to `s3://vault-backups/` in MinIO.

**Why DB-aware over PV-level:**
- WAL backups give point-in-time recovery to any second within the retention window — PV snapshots give you the moment the snapshot ran.
- Each consumer has a **scoped MinIO user** (`cnpg-bk-*`, `vault-sn-*`) bound to a bucket-scoped IAM policy. A compromised Vault snapshot user can't touch CNPG backups and vice versa.

Production pivot (Longhorn, off-cluster MinIO, multi-region replication, scheduled restore drill) is in [docs/backup-recovery.md](docs/backup-recovery.md) and [docs/production-gaps.md](docs/production-gaps.md).

### Wrapper Helm charts over umbrella charts

**Decision.** `charts/keycloak/`, `charts/minio/`, `charts/monitoring/` wrap upstream charts as **subchart dependencies** and add our own templates (ExternalSecrets, Ingresses, NetworkPolicies, Namespace PSS labels, CNPG Cluster + ScheduledBackup).

**Why wrap, not fork:**
- Upstream versioning + bug fixes flow through automatically (`helm dependency update`).
- Our additions live in `charts/<app>/templates/` — version-controlled, reviewable, no diff against the upstream chart.
- Same pattern transfers to the next workload (write a wrapper, list it as an Argo Application). No "framework" to maintain.

### Pulumi+Go mirror of the Terraform layer

**Decision.** A working Pulumi+Go implementation in `pulumi/` reaches the same Healthy cluster as the Terraform path. Same Vagrantfile, same `argocd/`, same `charts/`, same `manifests/`. Only the IaC tool differs.

**Why the mirror exists:**
- Demonstrates that **the GitOps tree is the actual platform**, and the IaC layer is interchangeable.
- A platform team standardized on Pulumi+Go can adopt this pattern without rewriting any of the application or configuration code.
- Both paths are exercised through identical bootstrap wrappers (`bootstrap.ps1` vs `bootstrap-pulumi.ps1`), so the reviewer sees genuine parity, not theoretical equivalence.

Design + validation log: [docs/pulumi-mirror.md](docs/pulumi-mirror.md).

## Prerequisites

### Host requirements

- **OS**: Windows 10/11, macOS, or Linux. Validated on Windows 11.
- **RAM**: 16 GB free recommended (12 GB for the VM + 4 GB host). 10 GB works but is tight under bootstrap load.
- **CPU**: 8+ physical cores recommended (8 vCPU for the VM + headroom).
- **Disk**: 50 GB free.
- **Virtualization**: VT-x / AMD-V enabled in BIOS.

> **Windows 11 — Hyper-V must be OFF.** VirtualBox cannot run while Hyper-V is enabled (they fight over the hardware-virtualization interfaces). Check + disable via:
> ```powershell
> # As Administrator
> bcdedit /enum | findstr hypervisorlaunchtype                  # check current state
> bcdedit /set hypervisorlaunchtype off                         # disable; requires reboot
> Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All   # full uninstall, also requires reboot
> ```

> **Clone path must not contain spaces.** The `kubectl apply -f <path>` step in the IaC layer uses a path argument that is shell-quoted only minimally. Stick to paths like `C:\Users\<name>\projects\iac-rke2-keycloak` (no `OneDrive` / `Program Files` paths with spaces).

### Tool list

**Common to both IaC paths (required regardless):**

| Tool | Min version | Check |
|---|---|---|
| **git** | any modern | `git --version` |
| **VirtualBox** | 7.0+ | `VBoxManage --version` |
| **Vagrant** | 2.4+ | `vagrant --version` |
| **kubectl** | 1.29+ | `kubectl version --client` |
| **Helm** | 3.14+ | `helm version --short` |

**Path A — Terraform only:**

| Tool | Min version | Check |
|---|---|---|
| **Terraform** | 1.6+ | `terraform version` |

**Path B — Pulumi + Go only:**

| Tool | Min version | Check |
|---|---|---|
| **Go** | 1.22+ | `go version` |
| **Pulumi CLI** | 3.140+ | `pulumi version` |

### Install (Windows 11 — winget)

```powershell
# Run as Administrator
winget install --id=Git.Git -e
winget install --id=Oracle.VirtualBox -e
winget install --id=Hashicorp.Vagrant -e
winget install --id=Kubernetes.kubectl -e
winget install --id=Helm.Helm -e
winget install --id=Hashicorp.Terraform -e   # Path A only
winget install --id=GoLang.Go -e             # Path B only
winget install --id=Pulumi.Pulumi -e         # Path B only

# Close + reopen PowerShell so PATH refreshes, then verify
git --version; VBoxManage --version; vagrant --version
kubectl version --client; helm version --short
terraform version    # Path A
go version           # Path B
pulumi version       # Path B
```

### Install (Ubuntu 22.04 / 24.04)

```bash
# Baseline + common deps
sudo apt update
sudo apt install -y curl gnupg lsb-release apt-transport-https ca-certificates git

# VirtualBox (Oracle repo, current versions)
wget -qO- https://www.virtualbox.org/download/oracle_vbox_2016.asc | sudo gpg --dearmor -o /usr/share/keyrings/oracle-virtualbox.gpg
echo "deb [signed-by=/usr/share/keyrings/oracle-virtualbox.gpg] https://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib" | sudo tee /etc/apt/sources.list.d/virtualbox.list
sudo apt update && sudo apt install -y virtualbox-7.0

# Vagrant + Terraform (HashiCorp repo)
wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y vagrant terraform           # terraform is Path A only

# kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /usr/share/keyrings/kubernetes.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update && sudo apt install -y kubectl

# Helm
curl -fsSL https://baltocdn.com/helm/signing.asc | sudo gpg --dearmor -o /usr/share/keyrings/helm.gpg
echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm.list
sudo apt update && sudo apt install -y helm

# Path B only — Go + Pulumi
sudo apt install -y golang-go                                       # ensure 1.22+, otherwise grab from go.dev/dl
curl -fsSL https://get.pulumi.com | sh
echo 'export PATH=$PATH:$HOME/.pulumi/bin' >> ~/.bashrc && source ~/.bashrc
```

### Install (macOS — Homebrew)

```bash
brew install --cask virtualbox vagrant
brew install kubectl helm git
brew install terraform                                              # Path A only
brew install go pulumi/tap/pulumi                                   # Path B only
```

### Running PowerShell scripts on Windows

Windows blocks unsigned PowerShell scripts by default. The bootstrap and init scripts in this repo are local files (not downloaded), so they're safe to run. Use the per-invocation bypass:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap.ps1
```

No system-wide policy change required. Alternatively, for an interactive session: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` (reverts on shell close).

## How it works

```
              ┌──────────────────────────────────┐
              │  bootstrap{,-pulumi}.{ps1,sh}    │
              │  reviewer picks ONE              │
              └────────────────┬─────────────────┘
                               │
            ┌──────────────────┴──────────────────┐
            │                                     │
   ┌────────▼────────┐                  ┌─────────▼─────────┐
   │ Path A          │                  │ Path B            │
   │ terraform apply │   ◄── same ──►   │ pulumi up         │
   │ terraform/      │   outcome,       │ pulumi/           │
   │                 │   different      │ (Go SDK)          │
   └────────┬────────┘   tool           └─────────┬─────────┘
            │                                     │
            └──────────────────┬──────────────────┘
                               │
              ┌────────────────▼─────────────────┐
              │  Either path performs:           │
              │    1. Vagrant provisions VM      │
              │    2. RKE2 single-node installs  │
              │    3. Kubeconfig exported to host│
              │    4. Helm installs ArgoCD       │
              │    5. kubectl apply root-app.yaml│
              └────────────────┬─────────────────┘
                             │
              ┌──────────────▼──────────────┐
              │  ArgoCD root Application     │
              │  (argocd/root-app.yaml)      │   Watches argocd/apps/*.yaml
              │  app-of-apps                 │   in this repo
              └──────────────┬──────────────┘
                             │
              ┌──────────────▼──────────────┐
              │  Child Applications sync     │   sync-wave ordered:
              │  by wave:                    │   -4 storage
              │  argocd/apps/*.yaml          │   -3 cert-manager + MetalLB
              │                              │   -2 issuers + Traefik + MetalLB-config
              │                              │   -1 operators (CNPG, Keycloak, Vault, ESO)
              │                              │    0 ESO config (ClusterSecretStore)
              │                              │    1 MinIO
              │                              │    2 Keycloak app
              │                              │    4 NetworkPolicies
              │                              │    5 Monitoring (kps + Loki + Promtail)
              └──────────────┬──────────────┘
                             │
              ┌──────────────▼──────────────┐
              │  bootstrap waits for         │   Pod-phase Running = sealed but
              │  vault-0 pod = Running       │   listening on :8200 (ready for init)
              └──────────────┬──────────────┘
                             │
              ┌──────────────▼──────────────┐
              │  init-vault.ps1 / .sh        │   - vault operator init (1 share)
              │                              │   - vault operator unseal
              │                              │   - kv put secret/<seed>
              │                              │   - vault auth enable kubernetes
              │                              │   - write eso-readonly policy + role
              │                              │   - keys -> terraform/vault-keys.json
              └──────────────┬──────────────┘
                             │
                       ESO catches up:
                       ClusterSecretStore -> Valid
                       Each ExternalSecret -> K8s Secret materialized
                       MinIO root creds + scoped users + Keycloak DB creds +
                       Keycloak admin bootstrap all appear.
                       Workload pods un-pend and reach Ready.
```

Re-running `bootstrap.ps1` is safe: terraform-apply is idempotent, `init-vault.ps1` skips paths that already exist, ArgoCD self-heals into the desired state.

## Hosts file — required for `*.lab.test` URLs

Apps are exposed at `https://<name>.lab.test`, served by Traefik behind the MetalLB IP `192.168.56.20`. Add the following line to your hosts file:

```
192.168.56.20  argocd.lab.test keycloak.lab.test minio.lab.test minio-api.lab.test vault.lab.test grafana.lab.test
```

| OS | Hosts file path |
|---|---|
| Windows | `C:\Windows\System32\drivers\etc\hosts` (edit as Administrator) |
| macOS / Linux | `/etc/hosts` (edit as root) |

PowerShell one-liner (run as Administrator):
```powershell
Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "192.168.56.20  argocd.lab.test keycloak.lab.test minio.lab.test minio-api.lab.test vault.lab.test grafana.lab.test"
```

## Trust the lab CA (optional — eliminates browser warnings)

The cluster issues all certs from a self-signed lab CA. Add the CA to your local trust store and `https://*.lab.test` URLs become trusted:

```powershell
# Extract the lab CA certificate
kubectl -n cert-manager get secret lab-ca-key-pair -o jsonpath="{.data.ca\.crt}" | `
  ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) } | `
  Set-Content "$env:USERPROFILE\Downloads\lab-ca.crt"

# Windows: double-click the cert → Install Certificate → Local Machine → Trusted Root Certification Authorities
# macOS:   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/lab-ca.crt
# Linux:   sudo cp lab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
```

Skip this step if you don't mind clicking through the browser warning on first visit.

## Credentials

All credentials are generated by `init-vault.ps1` (random 32-char alphanumeric) and stored in Vault. ESO materializes K8s Secrets from there; retrieve via kubectl:

```powershell
# ArgoCD
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | `
  %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}
# Username: admin

# Keycloak master-realm admin
kubectl -n keycloak get secret keycloak-bootstrap-admin -o jsonpath="{.data.password}" | `
  %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}
# Username: admin

# MinIO root password
kubectl -n minio get secret minio-root-credentials -o jsonpath="{.data.root-password}" | `
  %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}
# MinIO root username
kubectl -n minio get secret minio-root-credentials -o jsonpath="{.data.root-user}" | `
  %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}

# Vault root token
(Get-Content terraform\vault-keys.json | ConvertFrom-Json).root_token

# Grafana
kubectl -n monitoring get secret grafana-admin -o jsonpath="{.data.admin-password}" | `
  %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}
# Username: admin
```

> **Security note:** `terraform/vault-keys.json` contains Vault's unseal key + root token in plaintext and is gitignored. In production this file would not exist — Vault would auto-unseal via cloud KMS (AWS KMS / GCP KMS / Azure Key Vault) and the root token would be revoked immediately after bootstrap.

## Backup & Recovery

Three independent layers:

| Layer | What | Where | Mechanism |
|---|---|---|---|
| **DB (Postgres)** | Continuous WAL + nightly base backups | `s3://cnpg-backups/keycloak/` in MinIO | CNPG `barmanObjectStore` + `ScheduledBackup` daily 02:00 |
| **Secrets (Vault)** | Raft snapshot of the entire secret tree | `s3://vault-backups/` in MinIO | Daily 03:00 CronJob (`manifests/vault-backup/cronjob.yaml`), authenticates via Vault k8s auth as SA `vault-snapshot` (policy: read on `sys/storage/raft/snapshot`) |
| **MinIO objects** | Local-path PVC, not externally replicated in the lab | n/a | Lab limitation — see [docs/backup-recovery.md](docs/backup-recovery.md) for the production answer (longhorn + multi-region S3) |

### Verify the CNPG (Postgres) backup works

#### Windows / PowerShell

```powershell
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

# Watch for phase: completed (~30-60s on the lab)
kubectl -n keycloak get backup keycloak-db-manual-1 -w

# See the actual objects in MinIO
$pod  = kubectl -n minio get pod -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}'
$root = (kubectl -n minio get secret minio-root-credentials -o jsonpath='{.data}' | ConvertFrom-Json)
$u    = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($root.'root-user'))
$p    = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($root.'root-password'))
kubectl -n minio exec $pod -- mc alias set local http://localhost:9000 $u $p
kubectl -n minio exec $pod -- mc ls --recursive local/cnpg-backups/
```

#### Linux / macOS / bash

```bash
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

# Watch for phase: completed (~30-60s on the lab)
kubectl -n keycloak get backup keycloak-db-manual-1 -w

# See the actual objects in MinIO
pod=$(kubectl -n minio get pod -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}')
u=$(kubectl -n minio get secret minio-root-credentials -o jsonpath='{.data.root-user}' | base64 -d)
p=$(kubectl -n minio get secret minio-root-credentials -o jsonpath='{.data.root-password}' | base64 -d)
kubectl -n minio exec "$pod" -- mc alias set local http://localhost:9000 "$u" "$p"
kubectl -n minio exec "$pod" -- mc ls --recursive local/cnpg-backups/
```

### Verify the Vault Raft snapshot CronJob works

The CronJob is scheduled daily at 03:00 — trigger a manual run right now to validate end-to-end. Auth model + container split is documented in [docs/backup-recovery.md](docs/backup-recovery.md#layer-2-vault-raft-snapshot).

#### Windows / PowerShell

```powershell
$jobName = "vault-snapshot-manual-$(Get-Date -Format yyyyMMddHHmmss)"
kubectl -n vault create job --from=cronjob/vault-snapshot $jobName

# Wait for completion (init container + main container, ~30-45s total)
kubectl -n vault wait --for=condition=complete job/$jobName --timeout=120s

# Inspect both container logs
kubectl -n vault logs job/$jobName -c snapshot
kubectl -n vault logs job/$jobName -c upload

# Set up mc alias and list vault-backups bucket
# (re-runnable on its own; doesn't depend on variables from the CNPG block above)
$pod  = kubectl -n minio get pod -l app.kubernetes.io/name=minio -o jsonpath='{.items[0].metadata.name}'
$root = (kubectl -n minio get secret minio-root-credentials -o jsonpath='{.data}' | ConvertFrom-Json)
$u    = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($root.'root-user'))
$p    = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($root.'root-password'))
kubectl -n minio exec $pod -- mc alias set local http://localhost:9000 $u $p
kubectl -n minio exec $pod -- mc ls --recursive local/vault-backups/
# Should show vault-snapshot-<timestamp>.snap
```

#### Linux / macOS / bash

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

### Restore drill

See [docs/backup-recovery.md](docs/backup-recovery.md) for the full PITR restore procedure (CNPG `bootstrap.recovery` against the backup object store).

## Tear down the cluster

Two paths — pick based on what you want next:

### Clean teardown (orderly Argo cascade)

Use this when you want the IaC tool to drive the destroy through the Argo finalizers cleanly. **Slow** — Argo's `resources-finalizer.argocd.argoproj.io` walks every child Application + every namespace + every PVC before releasing the root Application; on a loaded VM this can take 10+ minutes or hang if anything has a stuck finalizer (PVC not releasing, namespace stuck Terminating, etc.).

**Path A — Terraform:**
```powershell
cd terraform
terraform destroy -auto-approve
```

**Path B — Pulumi:**
```powershell
cd pulumi
$env:PULUMI_CONFIG_PASSPHRASE = 'lab-passphrase-change-me'
pulumi destroy --yes --stack dev
```

If either hangs at the root-app deletion step, see the "unstick a hung delete" recipe below.

### Nuclear teardown (faster, equivalent end state)

Use this when the VM is going away anyway (rebuild from scratch, switching IaC paths, etc.). Skips the orderly Argo finalizer walk entirely — the VM is gone in seconds, so the in-cluster finalizers can't keep anything alive.

```powershell
cd C:\Users\ahmed\OneDrive\Desktop\iac-rke2-keycloak

# 1. Destroy the VM directly (bypasses every Argo finalizer)
vagrant destroy -f

# 2. Confirm nothing's left
vagrant status                             # "default not created" or "environment has not been created"
VBoxManage list runningvms                 # empty
VBoxManage list vms | findstr rke2-server-1   # empty
```

If `VBoxManage list vms` still shows `rke2-server-1` (Vagrant lost track of the registration):

```powershell
VBoxManage controlvm rke2-server-1 poweroff 2>$null
VBoxManage unregistervm rke2-server-1 --delete
```

### Clean local state files

Both paths leave artifacts on the host. After either teardown:

```powershell
cd C:\Users\ahmed\OneDrive\Desktop\iac-rke2-keycloak

# Cluster credentials (Vagrant writes this; not gitignored from the running cluster's perspective, just from this repo)
Remove-Item kubeconfig -ErrorAction SilentlyContinue

# Vault unseal key + root token (gitignored — local-only)
Remove-Item terraform\vault-keys.json -ErrorAction SilentlyContinue

# Path A — Terraform state (gitignored, but stale after a nuclear destroy)
Remove-Item terraform\terraform.tfstate, terraform\terraform.tfstate.backup -ErrorAction SilentlyContinue

# Path B — Pulumi local state (under ~/.pulumi; or wherever your `pulumi login --local` points)
# Removing the stack lets the next `pulumi up` start from scratch:
cd pulumi
pulumi stack rm dev --yes
cd ..
```

### Unstick a hung Argo cascade-delete

If `terraform destroy` / `pulumi destroy` stalls at the root Application deletion step (the most common stall — Argo waiting on a child Application's finalizer that's waiting on a PVC that won't release), force-strip the finalizers from a **separate** PowerShell window:

```powershell
$env:KUBECONFIG = "C:\Users\ahmed\OneDrive\Desktop\iac-rke2-keycloak\kubeconfig"

# See what's still hanging around
kubectl -n argocd get applications

# Strip the cascade-delete finalizer from every Application
kubectl -n argocd get applications -o name | ForEach-Object {
  kubectl -n argocd patch $_ --type=merge -p '{\"metadata\":{\"finalizers\":[]}}'
}

# The same trick for the root Application if it's the hung one
kubectl -n argocd patch app root --type=merge -p '{\"metadata\":{\"finalizers\":[]}}'
```

Once the finalizers are gone, the kubectl-delete the IaC tool is waiting on returns immediately and the destroy proceeds.

### Recipe for "destroy + rebuild on the other IaC path"

The fastest reset between IaC paths (Terraform → Pulumi, or vice versa). Both target the same VM name and host-only IP, so the previous path's VM must be fully gone before the next path's `up` runs.

```powershell
cd C:\Users\ahmed\OneDrive\Desktop\iac-rke2-keycloak

# 1. Nuke the VM and all local state in one go
vagrant destroy -f
Remove-Item kubeconfig, terraform\vault-keys.json -ErrorAction SilentlyContinue
Remove-Item terraform\terraform.tfstate, terraform\terraform.tfstate.backup -ErrorAction SilentlyContinue

# 2. Confirm the VirtualBox slot is empty
VBoxManage list vms | findstr rke2-server-1     # should be empty

# 3. Bootstrap on the OTHER path
# Path A → B:  powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap-pulumi.ps1 -WaitForHealthy
# Path B → A:  powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap.ps1 -WaitForHealthy
```

## Production gaps (what I would change for production)

See [docs/production-gaps.md](docs/production-gaps.md).

Key items:
- **Provisioning pipeline** — Vagrant + VirtualBox → Terraform (vSphere / Harvester / Metal³ / cloud) + cloud-init + Ansible. Vagrant is PoC-only.
- **HA RKE2** — 3 dedicated control-plane nodes (etcd-only, tainted) + N workers + 2 LB VMs (HAProxy + keepalived) — or a real cloud K8s
- **Storage pivot** — Longhorn replaces local-path as the default StorageClass (dedicated raw SSD/NVMe per worker, separate from OS); MinIO moves off-cluster onto dedicated VMs (separate failure domain). RKE2 etcd snapshots + Longhorn backups + CNPG WAL all stream to the external MinIO.
- **HA Vault** — 3 replicas + KMS auto-unseal (AWS KMS / GCP KMS), no plaintext `vault-keys.json`
- **OIDC SSO** — Keycloak as identity provider for ArgoCD + Grafana + MinIO
- **App-level metrics** — ServiceMonitor CRs per workload + matching NetworkPolicy ingress rules (lab is cluster-level only)
- **Promtail → Grafana Alloy** migration
- **Image scanning + signing** (Trivy + Cosign + admission webhook)
- **Resource quotas + LimitRanges** per namespace
- **Public ACME issuer** instead of the self-signed lab CA

## Repository layout

```
.
├── README.md                            this file
├── Vagrantfile                          openSUSE Leap 15.6 VM definition
├── terraform/                            Path A — Terraform IaC (default)
│   ├── main.tf                          VM provisioning + Helm-install ArgoCD + kubectl-apply root-app
│   ├── providers.tf                     helm + kubernetes providers (kubectl-via-local-exec to avoid kubectl provider init-time bug)
│   ├── variables.tf                     VM sizing, RKE2 version, ArgoCD chart version
│   └── outputs.tf
├── pulumi/                              Path B — Pulumi+Go mirror (stretch S2, validated end-to-end)
│   ├── go.mod                           module: github.com/asafwat/iac-rke2-keycloak/pulumi
│   ├── Pulumi.yaml                      project: runtime go, local state backend
│   ├── Pulumi.dev.yaml                  stack config — mirrors terraform/variables.tf defaults
│   ├── main.go                          wires vagrant + argocd resources
│   └── pkg/{config,vagrant,argocd}/     typed config + VM lifecycle + Helm release wrappers
├── argocd/
│   ├── root-app.yaml                    the one Application Terraform applies
│   └── apps/                            child Applications discovered by root-app
│       ├── local-path.yaml              storage (wave -4)
│       ├── cert-manager.yaml            CRDs + controllers (wave -3)
│       ├── metallb.yaml                 LoadBalancer (wave -3)
│       ├── traefik.yaml                 Ingress controller (wave -2)
│       ├── cert-manager-issuers.yaml    lab CA + ClusterIssuer (wave -2)
│       ├── metallb-config.yaml          IPAddressPool + L2Advertisement (wave -2)
│       ├── vault.yaml                   Vault Raft StatefulSet (wave -1)
│       ├── external-secrets.yaml        ESO controllers (wave -1)
│       ├── cnpg-operator.yaml           CloudNativePG (wave -1)
│       ├── keycloak-operator.yaml       Keycloak operator + CRDs (wave -1)
│       ├── external-secrets-config.yaml ClusterSecretStore (wave 0)
│       ├── minio.yaml                   wrapper chart at charts/minio (wave 1)
│       ├── argocd-ingress.yaml          ArgoCD ingress + TLS (wave 0)
│       ├── keycloak.yaml                wrapper chart at charts/keycloak (wave 2)
│       ├── vault-backup.yaml            Vault Raft snapshot CronJob (wave 3)
│       ├── networkpolicies.yaml         policies for un-wrappered namespaces (wave 4)
│       └── monitoring.yaml.disabled     wrapper chart at charts/monitoring (wave 5) — DISABLED in PoC; rename to .yaml to enable
├── charts/
│   ├── keycloak/                        wrapper: CNPG Cluster + ScheduledBackup + Keycloak CR + Ingress + ExternalSecrets + NetworkPolicies + Namespace PSS labels
│   ├── minio/                           wrapper: bitnami/minio subchart + ESO secrets + NetworkPolicies
│   └── monitoring/                      wrapper: kube-prometheus-stack + loki + promtail subcharts + ESO Grafana admin + Ingress + NetworkPolicies + Loki datasource
├── manifests/
│   ├── local-path/install.yaml          local-path-provisioner (default StorageClass)
│   ├── cert-manager/                    selfSigned-bootstrap → lab-ca Cert → lab-ca-issuer ClusterIssuer
│   ├── metallb/                         IPAddressPool + L2Advertisement
│   ├── external-secrets/                ClusterSecretStore pointing at Vault
│   ├── keycloak-operator/               vendored upstream operator + CRDs (no Helm chart available)
│   ├── argocd/                          ArgoCD ingress + TLS
│   ├── root/                            root-app target manifest (not used; root-app reads argocd/apps via app-of-apps)
│   ├── networkpolicies/policies.yaml    default-deny + allow-listed for un-wrappered namespaces
│   └── vault-backup/                    Phase 11 — Vault Raft snapshot CronJob (SA, ESO, NetPol, CronJob)
├── scripts/
│   ├── ps/
│   │   ├── bootstrap.ps1                Path A — Terraform bootstrap wrapper (Windows)
│   │   ├── bootstrap-pulumi.ps1         Path B — Pulumi bootstrap wrapper (Windows)
│   │   └── init-vault.ps1               init + unseal + seed + ESO + vault-snapshot roles (Windows, shared by both paths)
│   └── bash/
│       ├── bootstrap.sh                 Path A — Terraform bootstrap wrapper (Linux/macOS)
│       ├── bootstrap-pulumi.sh          Path B — Pulumi bootstrap wrapper (Linux/macOS)
│       └── init-vault.sh                init + unseal + seed + ESO + vault-snapshot roles (Linux/macOS, shared by both paths)
└── docs/
    ├── decisions.md                     non-obvious design choices with rationale (gitignored — local notes)
    ├── backup-recovery.md               backup architecture + restore drill
    ├── pulumi-mirror.md                 Pulumi+Go mirror design + validation log
    └── production-gaps.md             "what I would change for production"
```

---

Licensed under the Apache License 2.0 — see [LICENSE](LICENSE).

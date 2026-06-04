# iac-rke2-keycloak

> Reproducible deployment of Keycloak on a local single-node RKE2 cluster.
> **Terraform (or Pulumi + Go) provisions the infrastructure** — Vagrant VM + RKE2
> single-node cluster — and **bootstraps ArgoCD as the GitOps controller**.
> ArgoCD then reconciles every other component from this repo: cert-manager,
> MetalLB, Traefik, Vault (Raft) + External Secrets Operator, MinIO,
> CloudNativePG-managed Postgres, Keycloak operator + Keycloak CR, NetworkPolicies,
> and the daily Vault Raft snapshot CronJob. TLS via cert-manager. Pod Security
> Standards `restricted` + default-deny NetworkPolicies for hardening.

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

**Beyond the brief:** Vault + ESO (no plaintext secrets in Git), CNPG operator (HA primary + replica + WAL backups to MinIO), Vault Raft snapshot CronJob, ArgoCD app-of-apps with sync waves + retry config, six design docs covering architecture, decisions, production gaps, HA pattern, backup/recovery, and Pulumi mirror.

## Assumptions and constraints

- **One IaC path per session.** Both Terraform and Pulumi target the same VirtualBox VM name (`rke2-server-1`) and host-only IP (`192.168.56.10`). Running both at once collides — pick one, then teardown before switching.
- **Validated platforms.** The **PowerShell** wrappers were exercised end-to-end on Windows 11 / PowerShell 5.1 for both IaC paths. The **bash** siblings mirror the PowerShell logic line-for-line but were not run end-to-end during the assessment — a Linux/macOS reviewer is the first to validate.
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

A condensed table of the non-obvious decisions. Each entry has a full **Decision + Why + Production answer** writeup in [docs/design-choices.md](docs/design-choices.md).

| Choice | One-line rationale |
|---|---|
| **IaC for the cluster, GitOps for the workloads** | Terraform/Pulumi installs only RKE2 + ArgoCD; everything else flows through ArgoCD pull-mode reconciliation |
| **CNPG operator over Helm-managed Postgres** | Operator handles failover, PITR, in-place major upgrades; Helm chart can't |
| **Official Keycloak operator over community charts** | Vendor-supported upgrade path; Infinispan + cluster mode are operator-native |
| **Vault + ESO for secrets, not Sealed Secrets** | Zero secret material in Git; audit trail in Vault, not Git history |
| **Vault bootstrap: imperative script (lab), declarative IaC + auto-unseal (prod)** | Init/unseal can't be done by the Vault Terraform provider; production uses KMS auto-unseal + TF provider for config |
| **Restricted PSS on the keycloak namespace** | Catches misconfig at admission, not at runtime |
| **Default-deny NetworkPolicies with per-app allow-lists** | Written from observed traffic at wave 4 — no guessing |
| **Self-signed lab CA, swappable to real PKI in one file** | App `Certificate` resources reference an issuer; swap the issuer kind in production |
| **Traefik over ingress-nginx** | ingress-nginx retired 2025-11-11; Traefik supports Gateway API |
| **MetalLB L2 mode** | No BGP-capable upstream router in VirtualBox; production flips to BGP CRs |
| **Layered backup: CNPG WAL + Vault Raft snapshot to MinIO** | DB-aware > PV-level; scoped per-consumer MinIO users for blast-radius containment |
| **Wrapper Helm charts over umbrella charts** | Upstream version flow stays automatic; our additions live in our templates |
| **Pulumi+Go mirror of the Terraform layer** | Proves the GitOps tree is platform-of-record; IaC tool is interchangeable |

For each choice, **why** we picked it, **what** the alternatives traded, and the **production answer** — see [docs/design-choices.md](docs/design-choices.md).


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

Copy-paste install commands for **Windows 11 (winget)**, **Ubuntu (apt)**, and **macOS (Homebrew)** — including the Windows Hyper-V conflict toggle and the PowerShell execution-policy bypass — live in [docs/install.md](docs/install.md).

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

### Verify the backups end-to-end (manual triggers)

Both pipelines support an immediate manual run for validation — create a one-shot `Backup` CR for CNPG, or `kubectl create job --from=cronjob/vault-snapshot` for Vault. Full dual-shell (PowerShell + bash) recipes including MinIO object listing live in [docs/backup-recovery.md](docs/backup-recovery.md#verify-the-backup-pipeline-works-one-shot-test).

### Restore drill

See [docs/backup-recovery.md](docs/backup-recovery.md) for the full PITR restore procedure (CNPG `bootstrap.recovery` against the backup object store).

## Tear down the cluster

Two paths: **orderly** (`terraform destroy` / `pulumi destroy --stack dev` — slow because Argo finalizers cascade) or **nuclear** (`vagrant destroy -f` — VM gone in seconds, equivalent end state). Detailed step-by-step including the orphan-VirtualBox-directory fix, the unstick-a-hung-Argo recipe, and the destroy-and-switch-IaC-path recipe live in [docs/teardown.md](docs/teardown.md).

Quick reference:

```powershell
# Nuclear (recommended when rebuilding anyway)
vagrant destroy -f
Remove-Item kubeconfig, terraform\vault-keys.json -ErrorAction SilentlyContinue
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
├── pulumi/                              Path B — Pulumi+Go mirror (validated end-to-end)
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
│   └── vault-backup/                    Vault Raft snapshot CronJob (SA, ESO, NetPol, CronJob)
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
    ├── architecture.md                  component map, trust boundaries, data flows, sync wave ordering
    ├── design-choices.md                full Decision + Why + Production answer for each architectural choice
    ├── install.md                       per-OS install commands (Windows winget / Ubuntu apt / macOS Homebrew + Hyper-V toggle)
    ├── teardown.md                      orderly + nuclear destroy recipes, orphan-VirtualBox-directory fix, IaC-path-switchover
    ├── backup-recovery.md               CNPG WAL + Vault Raft snapshot pipelines, verify recipes, restore drill
    ├── pulumi-mirror.md                 Pulumi+Go mirror design + provider-equivalence table + validation log
    ├── ha-pattern.md                    production HA pivot — Terraform/Pulumi + cloud-init + Ansible, control-plane isolation
    ├── autoscaling-on-prem.md           on-prem autoscaling — Cluster API + cluster-autoscaler per substrate (vSphere/Harvester/Metal³)
    ├── production-gaps.md               "what I would change for production" — every PoC trade-off named explicitly
    └── decisions.md                     non-obvious design choices with rationale (gitignored — local notes)
```

---

Licensed under the Apache License 2.0 — see [LICENSE](LICENSE).

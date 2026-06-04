# Design choices

These are the non-obvious decisions that shaped the architecture. Each one trades a different thing. Linked from [`../README.md`](../README.md).

## Bootstrap split: IaC for the cluster, GitOps for the workloads

**Decision.** Terraform / Pulumi installs **RKE2, ArgoCD and the root Application**. Every other component — cert-manager, MetalLB, Traefik, Vault, ESO, MinIO, CNPG, Keycloak, NetworkPolicies, monitoring — is declared in `argocd/` and `charts/` and reconciled by ArgoCD from this repo.

**Why not "Terraform-all-the-things":**
- **State + lifecycle mismatch.** Terraform's state model assumes static infrastructure; Kubernetes workloads are inherently dynamic (operator-managed pods, autoscalers, controllers reconciling). Terraform fighting controllers over the same resource produces drift the operator considers "normal" and Terraform considers "broken."
- **Pull-mode reconciliation > push-mode apply.** ArgoCD continuously reconciles desired-state against actual-state. Drift detection and self-healing are free. Terraform only acts when you run `apply`.
- **Operational surface area.** A `terraform apply` failure mid-run on 30+ Kubernetes resources is an operational nightmare. ArgoCD's per-Application status, retry/backoff, and prune semantics are purpose-built for this.
- **Audit + review workflow.** A `git push` to `charts/keycloak/values.yaml` is a reviewable PR with full history; a change to a value buried in a Terraform module is harder to spot in code review.

The IaC layer's job is the one thing GitOps can't do for itself: **create the cluster the GitOps tool runs on**.

## Postgres via the CloudNativePG operator, not a Helm-managed Postgres

**Decision.** Keycloak's database is a CNPG `Cluster` resource (operator-managed StatefulSet), not the Postgres subchart of the Bitnami chart or a hand-rolled StatefulSet.

**Why CNPG:**
- **Operator handles the full DB lifecycle:** primary/replica election, failover, rolling upgrades, in-place major-version upgrades, role + user provisioning, backups via `barmanObjectStore`, point-in-time recovery — none of which a Helm chart can do declaratively.
- **CR is the API.** Changing `spec.instances: 2 → 3` triggers a controlled rolling expansion; changing `spec.imageName` to a newer Postgres triggers a rolling upgrade with WAL-consistent failover. Helm `replicaCount` can't do that safely.
- **Backups are first-class.** `Backup` and `ScheduledBackup` CRs are part of the same API as the cluster definition. No separate backup tool.

## Keycloak via the official Keycloak operator, not a community Helm chart

**Decision.** The `Keycloak` CR from the official Keycloak operator (`k8s.keycloak.org/v2alpha1`) — vendored upstream — owns the workload. Our wrapper chart provides the Keycloak CR + Ingress + ExternalSecrets + NetworkPolicies + namespace PSS labels around it.

**Why the official operator:**
- **Vendor-supported upgrade path.** The Keycloak project ships and tests the operator alongside each Keycloak release. Community charts lag behind.
- **Realm import / cluster mode / DB connection are operator-native.** Multi-replica with Infinispan cache, JGroups discovery via headless Service, sticky sessions — the operator wires these correctly. A bare Helm chart doesn't.
- **`unsupported.podTemplate` escape hatch** for security-context overrides (drop ALL caps, runAsNonRoot, seccomp RuntimeDefault) without forking the operator.

## Vault + External Secrets Operator (ESO), not Sealed Secrets or raw `kubectl create secret`

**Decision.** Secrets live in Vault (Raft storage, KV v2 engine at `secret/`). Every K8s Secret is materialized via an `ExternalSecret` CR that ESO resolves against the `ClusterSecretStore: vault`.

**Why this pairing:**
- **Zero secret material in Git.** Even encrypted. Sealed Secrets keeps an encrypted blob in Git; rotation = re-encrypt + commit + push. ESO + Vault: rotate in Vault, ESO repulls.
- **Audit trail in Vault, not Git history.** Vault audit log captures every read; Git history exposes secret rotation timing to anyone with repo access.
- **Authentication via Kubernetes auth method.** ESO talks to Vault using its own pod's ServiceAccount JWT — no static credentials, no manual token plumbing.
- **Centralized for multi-cluster.** Future multi-cluster fleets resolve the same secret paths from the same Vault.

## Vault bootstrap: imperative script in the lab, declarative IaC + auto-unseal in production

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

Full production posture in [production-gaps.md](production-gaps.md) under "Vault — HA mode" and "Vault config — Terraform provider for declarative state."

## Pod Security Standards `restricted` enforced on the Keycloak namespace

**Decision.** The `keycloak` namespace carries `pod-security.kubernetes.io/enforce: restricted` (PSA enforce mode). Keycloak app pods + Keycloak operator + CNPG Postgres pods all comply.

**Why restricted, not baseline:**
- `restricted` is the strictest standard PSS profile — runAsNonRoot, drop ALL capabilities, allowPrivilegeEscalation: false, RuntimeDefault seccomp, no host namespaces, no privileged containers.
- It catches misconfigurations at admission (`kubectl apply` is rejected) instead of at runtime (probe failures / silent compromises).
- It documents the workload's actual privileges in the namespace itself — a reviewer can see PSS posture without inspecting every pod spec.

Production extends this to every workload namespace; documented in [production-gaps.md](production-gaps.md).

## Default-deny NetworkPolicies, per-app allow-lists written from observed traffic

**Decision.** Every workload namespace ships a `default-deny-all` NetworkPolicy plus explicit allow-listed pinholes (Traefik → backends, ESO → Vault, CNPG → MinIO, Keycloak → Postgres, etc.). Policies are written from **observed traffic**, not guessed.

**Why this order:**
- Cluster boots with no NetworkPolicies (wave 4 is the last to apply) → real traffic patterns emerge under load → policies are written to match exactly that graph.
- Discovery-first means we don't accidentally over-allow (`{}` ingress) or under-allow (forgetting a path).
- Wave-4 ordering also means debugging is easier: cluster is known-good before policies land, so any post-wave-4 break is unambiguously a NetworkPolicy issue.

## Self-signed lab CA via cert-manager, swappable to real PKI in one file

**Decision.** A `selfSigned-bootstrap` Issuer signs the lab CA cert, which becomes the `lab-ca-issuer` ClusterIssuer that signs every workload cert. App `Certificate` resources reference the ClusterIssuer by name.

**Why this shape:**
- One-file production swap: replace the `lab-ca-issuer` ClusterIssuer manifest with `acme` (Let's Encrypt), `vault` (Vault PKI), or any other cert-manager issuer kind. App manifests stay untouched.
- Vault PKI is the production answer for sovereign-data deployments (the issuer runs in-cluster, no external dependency) — `production-gaps.md` covers the swap.

## Traefik for Ingress, not ingress-nginx

**Decision.** Traefik (installed via ArgoCD, version-pinned chart) handles all `*.lab.test` ingress. RKE2's bundled `rke2-ingress-nginx` is explicitly disabled.

**Why not ingress-nginx:**
- The `kubernetes/ingress-nginx` project is officially retired as of [2025-11-11](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/). Carrying a retired ingress into a new deployment is technical debt by day one.
- Traefik supports both Ingress v1 and Gateway API, has active vendor backing, and integrates cleanly with cert-manager via annotations.

## MetalLB L2 mode for LoadBalancer Services

**Decision.** MetalLB in L2 (ARP) mode advertises the `192.168.56.20-29` pool on the host-only network. Traefik's Service is `type: LoadBalancer` and picks up `192.168.56.20`.

**Why L2 (not BGP):**
- The VirtualBox host-only network has no BGP-capable upstream router to peer with — L2 is the only mode that works here.
- Production with a BGP-capable spine would flip `IPAddressPool` + `BGPAdvertisement` and add `BGPPeer` CRs — no other changes needed.

## Layered backup: DB-aware, not just PV snapshots

**Decision.** Two independent backup pipelines run on a daily schedule:
- **CNPG `barmanObjectStore`** ships continuous WAL + nightly base backups to `s3://cnpg-backups/keycloak/` in MinIO.
- **Vault Raft snapshot** CronJob runs at 03:00 (`manifests/vault-backup/cronjob.yaml`), authenticates to Vault via the kubernetes auth method, and uploads to `s3://vault-backups/` in MinIO.

**Why DB-aware over PV-level:**
- WAL backups give point-in-time recovery to any second within the retention window — PV snapshots give you the moment the snapshot ran.
- Each consumer has a **scoped MinIO user** (`cnpg-bk-*`, `vault-sn-*`) bound to a bucket-scoped IAM policy. A compromised Vault snapshot user can't touch CNPG backups and vice versa.

Production pivot (Longhorn, off-cluster MinIO, multi-region replication, scheduled restore drill) is in [backup-recovery.md](backup-recovery.md) and [production-gaps.md](production-gaps.md).

## Wrapper Helm charts over umbrella charts

**Decision.** `charts/keycloak/`, `charts/minio/`, `charts/monitoring/` wrap upstream charts as **subchart dependencies** and add our own templates (ExternalSecrets, Ingresses, NetworkPolicies, Namespace PSS labels, CNPG Cluster + ScheduledBackup).

**Why wrap, not fork:**
- Upstream versioning + bug fixes flow through automatically (`helm dependency update`).
- Our additions live in `charts/<app>/templates/` — version-controlled, reviewable, no diff against the upstream chart.
- Same pattern transfers to the next workload (write a wrapper, list it as an Argo Application). No "framework" to maintain.

## Pulumi+Go mirror of the Terraform layer

**Decision.** A working Pulumi+Go implementation in `pulumi/` reaches the same Healthy cluster as the Terraform path. Same Vagrantfile, same `argocd/`, same `charts/`, same `manifests/`. Only the IaC tool differs.

**Why the mirror exists:**
- Demonstrates that **the GitOps tree is the actual platform**, and the IaC layer is interchangeable.
- A platform team standardized on Pulumi+Go can adopt this pattern without rewriting any of the application or configuration code.
- Both paths are exercised through identical bootstrap wrappers (`bootstrap.ps1` vs `bootstrap-pulumi.ps1`), so the reviewer sees genuine parity, not theoretical equivalence.

Design + validation log: [pulumi-mirror.md](pulumi-mirror.md).

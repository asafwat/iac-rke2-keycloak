# Pulumi + Go IaC layer

Mirror of `terraform/` — same outcome, different tool. Reach the same Healthy
cluster as `terraform apply` from the sibling directory. Pick ONE IaC path
per session; both target the same VirtualBox VM name (`rke2-server-1`) and
host-only IP (`192.168.56.10`).

Design rationale + provider-equivalence table: [`../docs/pulumi-mirror.md`](../docs/pulumi-mirror.md).

## Prerequisites

On top of the host requirements in the repo root [README.md](../README.md)
(VirtualBox, Vagrant, kubectl, helm), the Pulumi path adds two tools:

| Tool | Minimum version | Check | Install |
|---|---|---|---|
| **Go** | 1.22+ | `go version` | `winget install GoLang.Go` (Windows), `brew install go` (macOS), package manager (Linux), or [go.dev/dl](https://go.dev/dl/) |
| **Pulumi** | 3.140+ | `pulumi version` | `winget install Pulumi.Pulumi` (Windows), `brew install pulumi/tap/pulumi` (macOS), or [pulumi.com/docs/install](https://www.pulumi.com/docs/install/) |

After installation **close and reopen your terminal** so the new PATH is
picked up.

```powershell
go version           # go version go1.23.x windows/amd64
pulumi version       # v3.140.x or newer
```

If you'd rather not install these and just want to run the assessment,
use the Terraform path (`scripts/ps/bootstrap.ps1` or
`scripts/bash/bootstrap.sh`) — same outcome, no Go required.

## Quick start

```powershell
# Windows / PowerShell
powershell -ExecutionPolicy Bypass -File ..\scripts\ps\bootstrap-pulumi.ps1 -WaitForHealthy
```

```bash
# Linux / macOS
../scripts/bash/bootstrap-pulumi.sh --wait-for-healthy
```

The bootstrap wrapper handles tool pre-flight, `pulumi login --local`, stack
init, `pulumi up`, the vault-0 wait, `init-vault.{ps1,sh}`, and the
optional all-Apps-Healthy wait. See the script for flags.

## Manual run

If you'd rather drive Pulumi directly:

```bash
cd pulumi
export PULUMI_CONFIG_PASSPHRASE='lab-passphrase-change-me'   # any non-empty string
pulumi login --local
pulumi stack init dev          # first time only
go mod download                # first time only
pulumi up                      # creates VM + RKE2 + ArgoCD + root-app

# Once the cluster is up, seed Vault + ESO:
../scripts/ps/init-vault.ps1   # or ../scripts/bash/init-vault.sh
```

## Layout

```
pulumi/
├── go.mod                   # github.com/asafwat/iac-rke2-keycloak/pulumi
├── Pulumi.yaml              # project: runtime: go, local backend
├── Pulumi.dev.yaml          # stack config — mirrors terraform/variables.tf
├── main.go                  # wires the resources below
└── pkg/
    ├── config/config.go     # typed config accessors (parallel to variables.tf)
    ├── vagrant/vm.go        # `vagrant up` + provisioner re-run
    └── argocd/install.go    # Helm v3 release + root-app kubectl apply
```

## Provider equivalence at a glance

| Terraform | Pulumi (this code) |
|---|---|
| `null_resource` + `local-exec "vagrant up"` | `command.local.NewCommand("rke2-vm-up")` |
| `null_resource` + `local-exec "vagrant provision"` | `command.local.NewCommand("rke2-vm-provision")` (re-runs on Vagrantfile hash change) |
| `helm_release "argocd"` | `helmv3.NewRelease("argocd-helm-release")` |
| `null_resource` + `local-exec "kubectl apply -f root-app.yaml"` | `command.local.NewCommand("argocd-root-app")` |
| `output "kubeconfig_path"` etc. | `ctx.Export("kubeconfig_path", ...)` |
| `terraform.tfstate` (local) | `~/.pulumi/` (via `pulumi login --local`) |

## State + secrets

- **Local state.** `pulumi login --local` writes state under `~/.pulumi`.
  Gitignored. No Pulumi cloud account required.
- **Passphrase.** Pulumi encrypts state secrets with
  `PULUMI_CONFIG_PASSPHRASE`. For the lab any non-empty string works; the
  bootstrap script sets a default if you forget. Override for any real use.
- **No app secrets cross the IaC boundary.** Same as Terraform: Vault
  credentials are seeded by `init-vault.{ps1,sh}` (NOT by Pulumi) and
  consumed by ESO. Pulumi state only contains VM specs + chart version.

## Destroying

```bash
cd pulumi
pulumi destroy --yes --stack dev
```

The `Delete` provisioners on the Pulumi Command resources run `vagrant
destroy -f` and `kubectl delete -f argocd/root-app.yaml --ignore-not-found`.
Equivalent to `terraform destroy` from the sibling directory.

## What is NOT done here

- The Vagrantfile shell provisioner is **not** rewritten in Go. Same file as
  the Terraform path — Pulumi only invokes `vagrant up`.
- The argocd/ + charts/ + manifests/ trees are **not** mirrored. Pulumi
  applies the same `argocd/root-app.yaml`, which discovers the same
  Applications, which sync the same charts and manifests. The platform
  state is identical.
- HA topology (3 control-plane + N workers + LB VMs) is **not** implemented
  here. The HA design pivots Vagrant → Terraform-with-real-providers +
  Ansible; see [`../docs/ha-pattern.md`](../docs/ha-pattern.md).

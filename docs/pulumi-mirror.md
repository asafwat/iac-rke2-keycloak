# Pulumi + Go mirror

> **Status: implemented and validated.** The Pulumi path reaches the same
> Healthy cluster as the Terraform path. Both compile cleanly, both
> resolve `pulumi preview` / `terraform plan` cleanly, and the Pulumi
> bootstrap was run end-to-end via `scripts/ps/bootstrap-pulumi.ps1`
> (which wraps `pulumi up` + the vault-0 wait + `init-vault.ps1` +
> the optional Apps-Healthy wait) on a freshly destroyed Terraform
> cluster. The point of the mirror is to demonstrate that the
> **GitOps tree is the actual platform** and the IaC layer is
> interchangeable — same outcome, different tool, reviewer's choice.

## What gets mirrored — and what doesn't

Only the `terraform/` directory has a Pulumi equivalent. Everything below
the IaC layer is unchanged:

| Layer | Path | Mirrored? |
|---|---|---|
| IaC (VM + ArgoCD install + root-app apply) | `terraform/` ↔ `pulumi/` | Yes — full parity |
| VM definition (provisioner shell, RKE2 install) | `Vagrantfile` | No — same file, called from both IaC paths |
| GitOps app declarations | `argocd/root-app.yaml`, `argocd/apps/*.yaml` | No — same files, byte-for-byte |
| Wrapper charts | `charts/keycloak/`, `charts/minio/`, `charts/monitoring/` | No |
| Raw manifests | `manifests/**` | No |
| Operational scripts | `scripts/ps/`, `scripts/bash/` | Wrappers gain a `bootstrap-pulumi.{ps1,sh}` sibling; `init-vault.{ps1,sh}` unchanged |

That's the headline: **two IaC implementations, one platform.** A reviewer
running `terraform apply` and a reviewer running `pulumi up` reach the
same cluster.

## Layout

```
pulumi/
├── go.mod                       # github.com/asafwat/iac-rke2-keycloak/pulumi
├── go.sum
├── Pulumi.yaml                  # project: runtime: go
├── Pulumi.dev.yaml              # stack config — mirrors terraform.tfvars values
├── main.go                      # entry point — thin, wires pkg/ resources
└── pkg/
    ├── config/
    │   └── config.go            # typed accessors mirroring terraform/variables.tf
    ├── vagrant/
    │   └── vm.go                # wraps pulumi-command for `vagrant up` + kubeconfig output
    └── argocd/
        └── install.go           # Helm v3 release + root-app kubectl-apply Command
```

`Vagrantfile`, `argocd/`, `charts/`, `manifests/`, `scripts/` — at the repo
root, untouched.

## Provider equivalence

| Terraform construct | Pulumi (Go) construct | Package |
|---|---|---|
| `null_resource` + `local-exec` for `vagrant up` | `command.local.Command` | `github.com/pulumi/pulumi-command/sdk/go/command/local` |
| `null_resource` + `local-exec` for `kubectl apply` | second `command.local.Command` | same |
| `helm_release` (ArgoCD chart) | `helm.v3.Release` | `github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes/helm/v3` |
| `variable` blocks | `pulumi.Config` accessors | `github.com/pulumi/pulumi/sdk/v3/go/pulumi/config` |
| `output` blocks | `ctx.Export("name", value)` | `github.com/pulumi/pulumi/sdk/v3/go/pulumi` |
| `depends_on` | `pulumi.DependsOn([]pulumi.Resource{...})` | same |
| `terraform.tfstate` | Pulumi state backend (`pulumi login --local`) | filesystem under `~/.pulumi/` |
| `terraform.tfvars` | `Pulumi.<stack>.yaml` | gitignored, same posture |

The 1:1 mapping is the point. Anyone fluent in either
tool can read the other.

## Stack config (`Pulumi.dev.yaml`)

Mirrors `terraform/variables.tf` defaults exactly so a reviewer can read
both side-by-side and see the parity:

```yaml
config:
  iac-rke2-keycloak:vm_box:                opensuse/Leap-15.6.x86_64
  iac-rke2-keycloak:vm_memory_mb:          "12288"
  iac-rke2-keycloak:vm_cpus:               "8"
  iac-rke2-keycloak:vm_ip:                 192.168.56.10
  iac-rke2-keycloak:vm_hostname:           rke2-server-1
  iac-rke2-keycloak:argocd_chart_version:  9.5.17
```

Same VM identity as Terraform (`rke2-server-1` / `192.168.56.10`) —
reviewers run one IaC path per session. Running both at once would
collide on the VirtualBox VM name and host-only network IP.

## `main.go` shape (sketch)

```go
package main

import (
    "github.com/pulumi/pulumi/sdk/v3/go/pulumi"

    "github.com/asafwat/iac-rke2-keycloak/pulumi/pkg/argocd"
    "github.com/asafwat/iac-rke2-keycloak/pulumi/pkg/config"
    "github.com/asafwat/iac-rke2-keycloak/pulumi/pkg/vagrant"
)

func main() {
    pulumi.Run(func(ctx *pulumi.Context) error {
        cfg := config.Load(ctx) // typed: VmMemoryMB, VmCpus, VmIP, ...

        vm, err := vagrant.NewVM(ctx, "rke2-vm", &vagrant.VMArgs{
            MemoryMB: cfg.VmMemoryMB,
            CPUs:     cfg.VmCpus,
            IP:       cfg.VmIP,
            Hostname: cfg.VmHostname,
        })
        if err != nil {
            return err
        }

        argo, err := argocd.NewInstall(ctx, "argocd", &argocd.InstallArgs{
            Kubeconfig:   vm.KubeconfigPath,
            ChartVersion: cfg.ArgocdChartVersion,
            RootAppPath:  "../argocd/root-app.yaml",
        }, pulumi.DependsOn([]pulumi.Resource{vm}))
        if err != nil {
            return err
        }

        ctx.Export("kubeconfig_path",     vm.KubeconfigPath)
        ctx.Export("vm_ip",               pulumi.String(cfg.VmIP))
        ctx.Export("argocd_password_cmd", argo.AdminPasswordCmd)
        return nil
    })
}
```

The `vagrant.NewVM` and `argocd.NewInstall` constructors each wrap a
`command.local.Command` and (for ArgoCD) the Helm Release. Total Go
codebase: ~250 lines across `pkg/`.

## State + secrets posture

- **Local backend.** `pulumi login --local` writes state to `~/.pulumi/`.
  Matches the assessment's no-external-services posture. The
  `.gitignore` already covers `pulumi/state/` and `Pulumi.*.yaml.bak`.
- **Passphrase encryption.** Pulumi encrypts secrets in state with a
  stack passphrase (`PULUMI_CONFIG_PASSPHRASE` env var). Equivalent
  posture to keeping `terraform.tfstate` local + gitignored.
- **No secrets cross the IaC boundary.** Same as Terraform — Vault
  credentials are seeded by `scripts/ps/init-vault.ps1` and consumed by
  ESO. The IaC layer (either one) only sees VM specs + the ArgoCD chart
  version. Nothing sensitive lands in Pulumi state.

## Bootstrap wrapper

A new `scripts/ps/bootstrap-pulumi.ps1` (and `.sh` sibling) sits next to
`bootstrap.ps1` as a parallel entry point. Same pipeline; only step 2
differs:

```
1. Pre-flight: vagrant, pulumi, kubectl, helm on PATH
2. cd pulumi && pulumi up --yes --stack dev       (instead of terraform apply)
3. Wait for vault-0 pod = Running
4. Run init-vault.{ps1,sh}                          (unchanged)
5. (Optional) wait for every Argo Application = Healthy
6. Print summary
```

The reviewer picks one wrapper or the other:

```powershell
# Terraform path
powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap.ps1 -WaitForHealthy

# Pulumi path
powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap-pulumi.ps1 -WaitForHealthy
```

Both end at the same Healthy cluster. The only on-disk difference is
which state directory holds the IaC record.

## What the mirror does NOT prove

- **It's not a load test.** Both tools call `vagrant up` the same way —
  the VM bring-up time, RKE2 install time, and ArgoCD sync time are
  identical. Performance is not the dimension being compared.
- **It's not a feature comparison.** Pulumi has stack references,
  dynamic providers, and richer state management. Terraform has a
  larger provider ecosystem and HCL's targeted DSL. Both can do this
  job; the choice depends on the team's language preference and
  tooling investment.
- **It's not an HA story.** Both implementations target a single VM in
  this assessment baseline. The HA pivot is in
  [`ha-pattern.md`](ha-pattern.md) — Terraform-with-real-providers
  (vSphere / Harvester / cloud) + Ansible. The same migration applies
  to the Pulumi side: swap the `command.local.Command` for the
  appropriate Pulumi provider (`pulumi-vsphere`,
  `pulumi-harvester-not-yet`, `pulumi-aws-ec2`, ...).

## What it does prove

- The GitOps tree (`argocd/`, `charts/`, `manifests/`) is the actual
  platform. The IaC layer is a thin shim that creates a Kubernetes
  cluster and points ArgoCD at this repo. Everything else flows from
  there.
- A platform team that has standardized on Pulumi+Go can adopt this
  exact pattern without rewriting any of the application or
  configuration code.
- The `ha_mode` conditional is materially nicer in Go than HCL:
  ```go
  if cfg.HaMode {
      for i, name := range []string{"rke2-server-2", "rke2-server-3"} {
          // join nodes as control-plane peers
      }
  }
  ```
  reads like normal code; HCL's `count = var.ha_mode ? 3 : 1` + indexed
  access works but is less natural.

## Validation log

What was actually exercised end-to-end during the assessment:

| Check | Result |
|---|---|
| `go build ./...` | Clean. No errors, no warnings. |
| `pulumi preview` (against a stack with `Pulumi.dev.yaml`) | Resolved 8 resources to create: stack → VM (component) → vm-up + vm-provision Commands; ArgoCD (component) → k8s provider + Helm Release + root-app Command. No errors. |
| `terraform destroy` of the existing TF-built cluster | VM gone, kubeconfig + vault-keys.json cleaned. |
| `scripts/ps/bootstrap-pulumi.ps1 -WaitForHealthy` (cold start) | Pre-flight passed, `pulumi up` built VM + installed RKE2 + ArgoCD + applied root-app, vault-0 reached Running, `init-vault.ps1` ran from within the wrapper, Vault initialized + unsealed + KV/k8s-auth enabled + ESO and `vault-snapshot` roles created. |
| ArgoCD reconciling child Apps | Same wave order, same Healthy end state as the TF path. |

The mirror is not a future commitment — it's in the repo, in
`pulumi/`, and the validation above was performed before merge.

**Platform note.** The validation above used the **PowerShell** wrapper
on Windows 11 / PS 5.1. The bash sibling (`scripts/bash/bootstrap-pulumi.sh`)
mirrors the PowerShell logic line-for-line — same `pulumi login --local`,
`pulumi stack init/select dev`, `go mod download`, `pulumi up --yes
--stack dev`, vault-0 wait, `init-vault.sh` invocation, optional
Apps-Healthy wait — but it was **not** run end-to-end during the
assessment. A reviewer on Linux/macOS using the bash path is the first
to validate it.
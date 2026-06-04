// Pulumi+Go mirror of terraform/main.tf. Reaches the same Healthy cluster
// as `terraform apply` from the sibling terraform/ directory:
//
//	vagrant up  →  RKE2 ready  →  ArgoCD installed  →  root Application applied
//
// Reviewers pick ONE IaC path per session — running both at once would
// collide on the VirtualBox VM name and the 192.168.56.10 host-only IP.
//
// See docs/pulumi-mirror.md for the design and the provider-equivalence table.
package main

import (
	"fmt"
	"path/filepath"
	"runtime"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"

	"github.com/asafwat/iac-rke2-keycloak/pulumi/pkg/argocd"
	"github.com/asafwat/iac-rke2-keycloak/pulumi/pkg/config"
	"github.com/asafwat/iac-rke2-keycloak/pulumi/pkg/vagrant"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.Load(ctx)

		repoRoot, err := repoRoot()
		if err != nil {
			return fmt.Errorf("resolve repo root: %w", err)
		}

		// ── VM lifecycle + provisioner re-run ───────────────────────────
		vm, err := vagrant.NewVM(ctx, "rke2-vm", &vagrant.VMArgs{
			Box:      cfg.VmBox,
			MemoryMB: cfg.VmMemoryMB,
			CPUs:     cfg.VmCpus,
			IP:       cfg.VmIP,
			Hostname: cfg.VmHostname,
			Rke2Ver:  cfg.Rke2Version,
			RepoRoot: repoRoot,
		})
		if err != nil {
			return fmt.Errorf("vagrant vm: %w", err)
		}

		// ── ArgoCD install + root-app apply ─────────────────────────────
		argo, err := argocd.NewInstall(ctx, "argocd", &argocd.InstallArgs{
			KubeconfigPath: vm.KubeconfigPath,
			ChartVersion:   cfg.ArgocdChartVersion,
			RepoRoot:       repoRoot,
		}, pulumi.DependsOn([]pulumi.Resource{vm}))
		if err != nil {
			return fmt.Errorf("argocd install: %w", err)
		}

		// ── Outputs — same names + intent as terraform/outputs.tf ───────
		ctx.Export("vm_ip", pulumi.String(cfg.VmIP))
		ctx.Export("vm_ssh_command", pulumi.Sprintf("cd %s && vagrant ssh", repoRoot))
		ctx.Export("kubeconfig_path", vm.KubeconfigPath)
		ctx.Export("argocd_port_forward",
			pulumi.String("kubectl -n argocd port-forward svc/argocd-server 8080:443"))
		ctx.Export("argocd_admin_password_cmd", argo.AdminPasswordCmd)
		return nil
	})
}

// repoRoot returns the absolute path to the repo root (parent of pulumi/).
// Equivalent to `abspath("${path.module}/..")` in terraform/main.tf.
//
// Uses runtime.Caller to anchor on this source file's location regardless
// of the working directory `pulumi up` was launched from.
func repoRoot() (string, error) {
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		return "", fmt.Errorf("runtime.Caller failed")
	}
	// main.go lives at <repoRoot>/pulumi/main.go → parent of parent.
	return filepath.Abs(filepath.Join(filepath.Dir(thisFile), ".."))
}

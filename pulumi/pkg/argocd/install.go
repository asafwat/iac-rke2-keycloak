// Package argocd installs ArgoCD via Helm and applies the root Application.
// Mirrors helm_release.argocd + null_resource.root_app from terraform/main.tf.
//
// Resource budgets and HA values match the Terraform sibling exactly so the
// rendered manifests are byte-identical regardless of which IaC tool ran.
package argocd

import (
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"

	"github.com/pulumi/pulumi-command/sdk/go/command/local"
	helmv3 "github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes/helm/v3"
	k8s "github.com/pulumi/pulumi-kubernetes/sdk/v4/go/kubernetes"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

type InstallArgs struct {
	// KubeconfigPath resolves to <repoRoot>/kubeconfig once the Vagrant
	// provisioner has written it. Pass vm.KubeconfigPath here so the helm
	// provider waits for the VM to be ready.
	KubeconfigPath pulumi.StringInput

	// ChartVersion pins the argo/argo-cd chart (matches var.argocd_chart_version).
	ChartVersion string

	// RepoRoot is the absolute path to the repo root (parent of pulumi/).
	// Used to locate argocd/root-app.yaml.
	RepoRoot string
}

type Install struct {
	pulumi.ResourceState

	HelmRelease *helmv3.Release
	RootApp     *local.Command

	// AdminPasswordCmd mirrors the Terraform output of the same name.
	AdminPasswordCmd pulumi.StringOutput `pulumi:"adminPasswordCmd"`
}

func NewInstall(ctx *pulumi.Context, name string, args *InstallArgs, opts ...pulumi.ResourceOption) (*Install, error) {
	inst := &Install{}
	if err := ctx.RegisterComponentResource("lab:argocd:Install", name, inst, opts...); err != nil {
		return nil, err
	}
	parent := pulumi.Parent(inst)

	// Helm provider configured against the kubeconfig the Vagrant provisioner
	// wrote. KubeconfigPath is an Output, so the provider is created lazily
	// once the VM is ready — equivalent to terraform's helm provider with
	// config_path pointing at the same file (which exists only after vagrant up).
	helmProvider, err := k8s.NewProvider(ctx, name+"-k8s-provider", &k8s.ProviderArgs{
		Kubeconfig: args.KubeconfigPath,
	}, parent)
	if err != nil {
		return nil, fmt.Errorf("helm provider: %w", err)
	}

	release, err := helmv3.NewRelease(ctx, name+"-helm-release", &helmv3.ReleaseArgs{
		Name:            pulumi.String("argocd"),
		Chart:           pulumi.String("argo-cd"),
		Version:         pulumi.String(args.ChartVersion),
		Namespace:       pulumi.String("argocd"),
		CreateNamespace: pulumi.Bool(true),
		Timeout:         pulumi.Int(600),
		// Pulumi-kubernetes helm.v3.Release WAITS by default (equivalent to
		// terraform helm_release `wait = true`). To explicitly NOT wait, set
		// SkipAwait: pulumi.Bool(true). We want the wait, so the default suffices.
		RepositoryOpts: &helmv3.RepositoryOptsArgs{
			Repo: pulumi.String("https://argoproj.github.io/argo-helm"),
		},
		Values: argocdValues(),
	}, parent, pulumi.Provider(helmProvider))
	if err != nil {
		return nil, fmt.Errorf("argocd helm release: %w", err)
	}
	inst.HelmRelease = release

	// Root Application apply via local-exec kubectl. Same rationale as the
	// Terraform side (see main.tf comment on null_resource.root_app):
	// applying the file via a typed Kubernetes resource forces the provider
	// to read the kubeconfig at registration time, which causes TLS verify
	// failures on a fresh clone. local-exec defers the read to runtime.
	rootAppPath := filepath.Join(args.RepoRoot, "argocd", "root-app.yaml")
	rootAppHash, err := fileMD5(rootAppPath)
	if err != nil {
		return nil, fmt.Errorf("hash root-app.yaml: %w", err)
	}

	rootApp, err := local.NewCommand(ctx, name+"-root-app", &local.CommandArgs{
		Create: pulumi.Sprintf("kubectl apply -f %s", rootAppPath),
		Delete: pulumi.Sprintf("kubectl delete -f %s --ignore-not-found", rootAppPath),
		Environment: pulumi.StringMap{
			"KUBECONFIG": args.KubeconfigPath,
		},
		Triggers: pulumi.Array{
			pulumi.String(rootAppHash),
			pulumi.String(rootAppPath),
			args.KubeconfigPath,
		},
	}, parent, pulumi.DependsOn([]pulumi.Resource{release}))
	if err != nil {
		return nil, fmt.Errorf("root-app apply: %w", err)
	}
	inst.RootApp = rootApp

	inst.AdminPasswordCmd = pulumi.String(
		"kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d",
	).ToStringOutput()

	if err := ctx.RegisterResourceOutputs(inst, pulumi.Map{
		"adminPasswordCmd": inst.AdminPasswordCmd,
	}); err != nil {
		return nil, err
	}
	return inst, nil
}

// argocdValues mirrors the yamlencode block in helm_release.argocd.values
// from terraform/main.tf. Same resource budgets, same flags. Kept inline
// (not loaded from a YAML file) so the two IaC paths are visibly identical
// in their source-of-truth views.
func argocdValues() pulumi.MapInput {
	return pulumi.Map{
		"global": pulumi.Map{
			"domain": pulumi.String("argocd.lab.test"),
		},
		"configs": pulumi.Map{
			"params": pulumi.Map{
				"server.insecure": pulumi.String("true"),
			},
		},
		"server": pulumi.Map{
			"service": pulumi.Map{
				"type": pulumi.String("ClusterIP"),
			},
			"resources": pulumi.Map{
				"requests": pulumi.Map{"cpu": pulumi.String("100m"), "memory": pulumi.String("128Mi")},
				"limits":   pulumi.Map{"cpu": pulumi.String("500m"), "memory": pulumi.String("256Mi")},
			},
		},
		"controller": pulumi.Map{
			"resources": pulumi.Map{
				"requests": pulumi.Map{"cpu": pulumi.String("100m"), "memory": pulumi.String("384Mi")},
				"limits":   pulumi.Map{"cpu": pulumi.String("500m"), "memory": pulumi.String("1Gi")},
			},
		},
		"repoServer": pulumi.Map{
			"resources": pulumi.Map{
				"requests": pulumi.Map{"cpu": pulumi.String("200m"), "memory": pulumi.String("256Mi")},
				"limits":   pulumi.Map{"cpu": pulumi.String("1000m"), "memory": pulumi.String("768Mi")},
			},
		},
		"applicationSet": pulumi.Map{
			"resources": pulumi.Map{
				"requests": pulumi.Map{"cpu": pulumi.String("50m"), "memory": pulumi.String("64Mi")},
				"limits":   pulumi.Map{"cpu": pulumi.String("200m"), "memory": pulumi.String("128Mi")},
			},
		},
		"notifications": pulumi.Map{
			"resources": pulumi.Map{
				"requests": pulumi.Map{"cpu": pulumi.String("50m"), "memory": pulumi.String("64Mi")},
				"limits":   pulumi.Map{"cpu": pulumi.String("200m"), "memory": pulumi.String("128Mi")},
			},
		},
		"dex": pulumi.Map{
			"resources": pulumi.Map{
				"requests": pulumi.Map{"cpu": pulumi.String("50m"), "memory": pulumi.String("64Mi")},
				"limits":   pulumi.Map{"cpu": pulumi.String("200m"), "memory": pulumi.String("128Mi")},
			},
		},
		"redis": pulumi.Map{
			"resources": pulumi.Map{
				"requests": pulumi.Map{"cpu": pulumi.String("50m"), "memory": pulumi.String("64Mi")},
				"limits":   pulumi.Map{"cpu": pulumi.String("200m"), "memory": pulumi.String("128Mi")},
			},
		},
	}
}

func fileMD5(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := md5.Sum(data)
	return hex.EncodeToString(sum[:]), nil
}

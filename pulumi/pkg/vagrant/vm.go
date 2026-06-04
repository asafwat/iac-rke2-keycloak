// Package vagrant wraps `vagrant up` / `vagrant provision` / `vagrant destroy`
// as Pulumi resources. Mirrors null_resource.vagrant_vm and
// null_resource.vagrant_provision from terraform/main.tf.
//
// The split between VM lifecycle (vagrant up) and provisioner re-run
// (vagrant provision) keeps shell-provisioner edits from forcing a full
// VM rebuild — same idea as the two null_resources in the Terraform path.
package vagrant

import (
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"

	"github.com/pulumi/pulumi-command/sdk/go/command/local"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

// VMArgs are the inputs that, when changed, force a VM rebuild.
// Matches the `triggers` block on null_resource.vagrant_vm.
type VMArgs struct {
	Box        string
	MemoryMB   int
	CPUs       int
	IP         string
	Hostname   string
	Rke2Ver    string
	RepoRoot   string // absolute path to repo root (parent of pulumi/)
}

// VM is the materialized lifecycle resource. Exposes KubeconfigPath as an
// Output so dependents (ArgoCD install) can wire ordering via DependsOn.
type VM struct {
	pulumi.ResourceState
	KubeconfigPath pulumi.StringOutput `pulumi:"kubeconfigPath"`

	up        *local.Command // `vagrant up`
	provision *local.Command // `vagrant provision` (re-run on Vagrantfile edits)
}

// NewVM creates the VM lifecycle + provisioner re-run pair.
func NewVM(ctx *pulumi.Context, name string, args *VMArgs, opts ...pulumi.ResourceOption) (*VM, error) {
	vm := &VM{}
	if err := ctx.RegisterComponentResource("lab:vagrant:VM", name, vm, opts...); err != nil {
		return nil, err
	}
	parent := pulumi.Parent(vm)

	// Environment passed to `vagrant up` matches the env block on
	// null_resource.vagrant_vm so the Vagrantfile reads identical values
	// regardless of which IaC tool drove the apply.
	vagrantEnv := pulumi.StringMap{
		"VM_BOX":       pulumi.String(args.Box),
		"VM_MEMORY":    pulumi.Sprintf("%d", args.MemoryMB),
		"VM_CPUS":      pulumi.Sprintf("%d", args.CPUs),
		"VM_IP":        pulumi.String(args.IP),
		"VM_HOSTNAME":  pulumi.String(args.Hostname),
		"RKE2_VERSION": pulumi.String(args.Rke2Ver),
	}

	// `triggers` on null_resource.vagrant_vm → Pulumi Command Triggers array.
	// Any change rebuilds the VM (vagrant up reads the modified Vagrantfile env).
	vmTriggers := pulumi.Array{
		pulumi.String(args.Box),
		pulumi.Sprintf("%d", args.MemoryMB),
		pulumi.Sprintf("%d", args.CPUs),
		pulumi.String(args.IP),
		pulumi.String(args.Hostname),
	}

	up, err := local.NewCommand(ctx, name+"-up", &local.CommandArgs{
		Create:   pulumi.String("vagrant up"),
		Delete:   pulumi.String("vagrant destroy -f"),
		Dir:      pulumi.String(args.RepoRoot),
		Environment: vagrantEnv,
		Triggers: vmTriggers,
	}, parent)
	if err != nil {
		return nil, fmt.Errorf("vagrant up: %w", err)
	}
	vm.up = up

	// `triggers.vagrantfile_hash = filemd5(...)` → compute MD5 in Go.
	// Read at registration time, identical to Terraform's filemd5() at plan time.
	hash, err := fileMD5(filepath.Join(args.RepoRoot, "Vagrantfile"))
	if err != nil {
		return nil, fmt.Errorf("hash Vagrantfile: %w", err)
	}

	provision, err := local.NewCommand(ctx, name+"-provision", &local.CommandArgs{
		Create:   pulumi.String("vagrant provision"),
		Dir:      pulumi.String(args.RepoRoot),
		Triggers: pulumi.Array{pulumi.String(hash)},
	}, parent, pulumi.DependsOn([]pulumi.Resource{up}))
	if err != nil {
		return nil, fmt.Errorf("vagrant provision: %w", err)
	}
	vm.provision = provision

	// The Vagrant shell provisioner writes <repoRoot>/kubeconfig with the
	// server URL rewritten to the VM IP. Path is deterministic; expose it
	// as an Output that depends on provision completing so downstream
	// resources wait for the kubeconfig to actually exist on disk.
	kubeconfig := filepath.Join(args.RepoRoot, "kubeconfig")
	vm.KubeconfigPath = provision.Stdout.ApplyT(func(_ string) string {
		return kubeconfig
	}).(pulumi.StringOutput)

	if err := ctx.RegisterResourceOutputs(vm, pulumi.Map{
		"kubeconfigPath": vm.KubeconfigPath,
	}); err != nil {
		return nil, err
	}
	return vm, nil
}

// fileMD5 mirrors Terraform's filemd5() function — used as the trigger for
// the provisioner re-run resource.
func fileMD5(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := md5.Sum(data)
	return hex.EncodeToString(sum[:]), nil
}

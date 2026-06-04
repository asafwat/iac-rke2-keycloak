// Package config mirrors terraform/variables.tf — typed accessors for the
// stack config keys. Same names and defaults as the Terraform variables so
// a reviewer can read both side-by-side.
package config

import (
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

// Config is the typed view of Pulumi.<stack>.yaml.
type Config struct {
	VmBox              string
	VmMemoryMB         int
	VmCpus             int
	VmIP               string
	VmHostname         string
	Rke2Version        string
	ArgocdChartVersion string
}

// Load reads the stack config with the same defaults as terraform/variables.tf.
// Calling Load() multiple times is safe — pulumi.config caches reads.
func Load(ctx *pulumi.Context) Config {
	c := config.New(ctx, "iac-rke2-keycloak")

	return Config{
		VmBox:              c.Get("vm_box"),
		VmMemoryMB:         c.GetInt("vm_memory_mb"),
		VmCpus:             c.GetInt("vm_cpus"),
		VmIP:               c.Get("vm_ip"),
		VmHostname:         c.Get("vm_hostname"),
		Rke2Version:        c.Get("rke2_version"),
		ArgocdChartVersion: c.Get("argocd_chart_version"),
	}
}

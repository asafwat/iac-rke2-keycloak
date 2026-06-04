terraform {
  required_version = ">= 1.6"

  required_providers {
    null       = { source = "hashicorp/null",      version = "~> 3.2" }
    local      = { source = "hashicorp/local",     version = "~> 2.5" }
    helm       = { source = "hashicorp/helm",      version = "~> 2.17" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    # gavinbunney/kubectl dropped: it reads the kubeconfig at provider-init
    # time, which is BEFORE the Vagrant provisioner writes the file on a fresh
    # clone, so it silently picks up a default with no CA and fails TLS verify.
    # The single Application CR it managed is now applied via local-exec
    # kubectl (see null_resource.root_app in main.tf).
  }
}

# All Kubernetes-aware providers read the kubeconfig the Vagrant provisioner wrote.
locals {
  kubeconfig_path = "${local.repo_root}/kubeconfig"
}

provider "helm" {
  kubernetes {
    config_path = local.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = local.kubeconfig_path
}
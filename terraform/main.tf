locals {
  repo_root = abspath("${path.module}/..")
}

# ── VM provisioning ───────────────────────────────────────────────────────────
#
# Two-resource split so editing the Vagrantfile (provisioner steps) does NOT
# destroy and recreate the VM. Only VM-defining attributes (box, IP, sizing)
# force a rebuild.

# 1. VM lifecycle - triggers only on attributes that genuinely require a rebuild.
resource "null_resource" "vagrant_vm" {
  triggers = {
    vm_box       = var.vm_box
    vm_memory_mb = var.vm_memory_mb
    vm_cpus      = var.vm_cpus
    vm_ip        = var.vm_ip
    vm_hostname  = var.vm_hostname
  }

  provisioner "local-exec" {
    command     = "vagrant up"
    working_dir = local.repo_root
    environment = {
      VM_BOX      = var.vm_box
      VM_MEMORY   = tostring(var.vm_memory_mb)
      VM_CPUS     = tostring(var.vm_cpus)
      VM_IP       = var.vm_ip
      VM_HOSTNAME = var.vm_hostname
    }
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "vagrant destroy -f"
    working_dir = "${path.module}/.."
  }
}

# 2. Re-runs the shell provisioner whenever Vagrantfile contents change.
#    Idempotent - just executes the shell block against the existing VM.
resource "null_resource" "vagrant_provision" {
  depends_on = [null_resource.vagrant_vm]

  triggers = {
    vagrantfile_hash = filemd5("${local.repo_root}/Vagrantfile")
  }

  provisioner "local-exec" {
    command     = "vagrant provision"
    working_dir = local.repo_root
  }
}

# ── ArgoCD bootstrap (the ONLY app Terraform installs) ────────────────────────
#
# After this, Terraform's job is done at the application layer.
# Every other workload (cert-manager, Traefik, MinIO, Vault, ESO, CNPG, Keycloak)
# is reconciled by ArgoCD from the Git repo via the root Application below.

resource "helm_release" "argocd" {
  depends_on = [null_resource.vagrant_provision]   # wait for RKE2 + provisioner to settle

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  namespace        = "argocd"
  create_namespace = true
  timeout          = 600   # ArgoCD has a lot of CRDs to register
  wait             = true

  values = [yamlencode({
    global = {
      domain = "argocd.lab.test"    # placeholder - real ingress arrives in Phase 4
    }
    configs = {
      params = {
        "server.insecure" = "true"   # TLS terminated at Traefik (Phase 4), not at ArgoCD
      }
    }
    # ── Single-replica on this single-node lab ────────────────────────────────
    # The HA configuration (redis-ha enabled + 2 replicas for server/repoServer/
    # applicationSet) requires multi-node scheduling - the redis-ha chart has
    # hard pod anti-affinity rules that hold pods Pending on a 1-node cluster.
    # HA values are documented in docs/production-gaps.md for the multi-node
    # production deployment (HA RKE2 stretch goal or real cloud cluster).
    #
    # Resource budgets sized for the 8 GB lab VM.
    server = {
      service   = { type = "ClusterIP" }
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "256Mi" }
      }
    }
    # Bumped memory: argocd-application-controller's RSS scales with the
    # number of Applications it tracks (we run ~14). 512Mi gets OOMKilled
    # at ~520Mi RSS during full-cluster reconciles. 1Gi gives headroom.
    controller = {
      resources = {
        requests = { cpu = "100m", memory = "384Mi" }
        limits   = { cpu = "500m", memory = "1Gi" }
      }
    }
    # Bumped CPU + memory: repo-server forks `helm template` for every app on
    # every reconcile. Rendering several large charts in parallel (cert-manager,
    # Traefik, MinIO, Keycloak) OOMKills at 256Mi - the gRPC connection drops
    # mid-render and ArgoCD reports "connection refused on port 8081" against
    # its own repo-server.
    repoServer = {
      resources = {
        requests = { cpu = "200m", memory = "256Mi" }
        limits   = { cpu = "1000m", memory = "768Mi" }
      }
    }
    applicationSet = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }
    }
    notifications = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }
    }
    dex = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }
    }
    redis = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "128Mi" }
      }
    }
  })]
}

# Root Application - the "app of apps" pattern entry point.
# ArgoCD watches argocd/apps/ in the Git repo and reconciles any Application it finds.
#
# Applied via local-exec kubectl rather than the kubectl_manifest resource.
# Reason: gavinbunney/kubectl reads the kubeconfig at provider INIT time (very
# start of `terraform apply`), but on a fresh clone the kubeconfig doesn't
# exist until after null_resource.vagrant_provision runs - so the provider
# silently falls back to a system default with no CA bundle and then fails
# TLS verification ("x509: certificate signed by unknown authority"). Helm
# avoids this by reading lazily. local-exec defers everything to runtime
# and picks up the kubeconfig as it exists at apply time.
resource "null_resource" "root_app" {
  depends_on = [helm_release.argocd]

  triggers = {
    root_app_hash   = filemd5("${local.repo_root}/argocd/root-app.yaml")
    root_app_path   = "${local.repo_root}/argocd/root-app.yaml"
    kubeconfig_path = local.kubeconfig_path
  }

  # Cross-shell safe: pass kubeconfig path via KUBECONFIG env var (Terraform
  # injects environment directly, no shell quoting), and the -f argument is
  # an unquoted absolute path (no spaces in the repo layout). Works on cmd.exe,
  # PowerShell, and bash without per-shell interpreter overrides.
  provisioner "local-exec" {
    command     = "kubectl apply -f ${local.repo_root}/argocd/root-app.yaml"
    environment = { KUBECONFIG = local.kubeconfig_path }
  }

  # Destroy provisioners can only reference self.triggers (no external locals).
  # --ignore-not-found makes destroy idempotent when the cluster is already gone.
  provisioner "local-exec" {
    when        = destroy
    command     = "kubectl delete -f ${self.triggers.root_app_path} --ignore-not-found"
    environment = { KUBECONFIG = self.triggers.kubeconfig_path }
  }
}

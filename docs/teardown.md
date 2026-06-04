# Tear down the cluster

Linked from [`../README.md`](../README.md). Two paths — pick based on what you want next.

## Clean teardown (orderly Argo cascade)

Use this when you want the IaC tool to drive the destroy through the Argo finalizers cleanly. **Slow** — Argo's `resources-finalizer.argocd.argoproj.io` walks every child Application + every namespace + every PVC before releasing the root Application; on a loaded VM this can take 10+ minutes or hang if anything has a stuck finalizer (PVC not releasing, namespace stuck Terminating, etc.).

**Path A — Terraform:**
```powershell
cd terraform
terraform destroy -auto-approve
```

**Path B — Pulumi:**
```powershell
cd pulumi
$env:PULUMI_CONFIG_PASSPHRASE = 'lab-passphrase-change-me'
pulumi destroy --yes --stack dev
```

If either hangs at the root-app deletion step, see [Unstick a hung Argo cascade-delete](#unstick-a-hung-argo-cascade-delete) below.

## Nuclear teardown (faster, equivalent end state)

Use this when the VM is going away anyway (rebuild from scratch, switching IaC paths, etc.). Skips the orderly Argo finalizer walk entirely — the VM is gone in seconds, so the in-cluster finalizers can't keep anything alive.

```powershell
cd C:\Users\ahmed\OneDrive\Desktop\iac-rke2-keycloak

# 1. Destroy the VM directly (bypasses every Argo finalizer)
vagrant destroy -f

# 2. Confirm nothing's left
vagrant status                             # "default not created" or "environment has not been created"
VBoxManage list runningvms                 # empty
VBoxManage list vms | findstr rke2-server-1   # empty
```

If `VBoxManage list vms` still shows `rke2-server-1` (Vagrant lost track of the registration):

```powershell
VBoxManage controlvm rke2-server-1 poweroff 2>$null
VBoxManage unregistervm rke2-server-1 --delete
```

**Always check for an orphaned VM directory after teardown.** `VBoxManage unregistervm --delete` removes the registration + most files but occasionally leaves the empty directory behind. The next `vagrant up` / `terraform apply` / `pulumi up` then fails with:

```
VBoxManage.exe: error: Could not rename the directory
  'C:\Users\<you>\VirtualBox VMs\Leap-15.6_<random>'
  to 'C:\Users\<you>\VirtualBox VMs\rke2-server-1' to save the settings file
  (VERR_ALREADY_EXISTS)
```

Fix — remove the orphan directory manually:

```powershell
Remove-Item "$env:USERPROFILE\VirtualBox VMs\rke2-server-1" -Recurse -Force -ErrorAction SilentlyContinue

# Confirm it's gone
Test-Path "$env:USERPROFILE\VirtualBox VMs\rke2-server-1"   # should print False
```

On macOS / Linux the equivalent path is `~/VirtualBox VMs/rke2-server-1` — `rm -rf "$HOME/VirtualBox VMs/rke2-server-1"` does the same.

## Clean local state files

Both paths leave artifacts on the host. After either teardown:

```powershell
cd C:\Users\ahmed\OneDrive\Desktop\iac-rke2-keycloak

# Cluster credentials (Vagrant writes this; not gitignored from the running cluster's perspective, just from this repo)
Remove-Item kubeconfig -ErrorAction SilentlyContinue

# Vault unseal key + root token (gitignored — local-only)
Remove-Item terraform\vault-keys.json -ErrorAction SilentlyContinue

# Path A — Terraform state (gitignored, but stale after a nuclear destroy)
Remove-Item terraform\terraform.tfstate, terraform\terraform.tfstate.backup -ErrorAction SilentlyContinue

# Path B — Pulumi local state (under ~/.pulumi; or wherever your `pulumi login --local` points)
# Removing the stack lets the next `pulumi up` start from scratch:
cd pulumi
pulumi stack rm dev --yes
cd ..
```

## Unstick a hung Argo cascade-delete

If `terraform destroy` / `pulumi destroy` stalls at the root Application deletion step (the most common stall — Argo waiting on a child Application's finalizer that's waiting on a PVC that won't release), force-strip the finalizers from a **separate** PowerShell window:

```powershell
$env:KUBECONFIG = "C:\Users\ahmed\OneDrive\Desktop\iac-rke2-keycloak\kubeconfig"

# See what's still hanging around
kubectl -n argocd get applications

# Strip the cascade-delete finalizer from every Application
kubectl -n argocd get applications -o name | ForEach-Object {
  kubectl -n argocd patch $_ --type=merge -p '{\"metadata\":{\"finalizers\":[]}}'
}

# The same trick for the root Application if it's the hung one
kubectl -n argocd patch app root --type=merge -p '{\"metadata\":{\"finalizers\":[]}}'
```

Once the finalizers are gone, the kubectl-delete the IaC tool is waiting on returns immediately and the destroy proceeds.

## Recipe for "destroy + rebuild on the other IaC path"

The fastest reset between IaC paths (Terraform → Pulumi, or vice versa). Both target the same VM name and host-only IP, so the previous path's VM must be fully gone before the next path's `up` runs.

```powershell
cd C:\Users\ahmed\OneDrive\Desktop\iac-rke2-keycloak

# 1. Nuke the VM and all local state in one go
vagrant destroy -f
Remove-Item kubeconfig, terraform\vault-keys.json -ErrorAction SilentlyContinue
Remove-Item terraform\terraform.tfstate, terraform\terraform.tfstate.backup -ErrorAction SilentlyContinue

# 2. Remove the orphaned VirtualBox VM directory if it survived (common; see note above)
Remove-Item "$env:USERPROFILE\VirtualBox VMs\rke2-server-1" -Recurse -Force -ErrorAction SilentlyContinue

# 3. Confirm the VirtualBox slot is empty
VBoxManage list vms | findstr rke2-server-1     # should be empty

# 4. Bootstrap on the OTHER path
# Path A → B:  powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap-pulumi.ps1 -WaitForHealthy
# Path B → A:  powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap.ps1 -WaitForHealthy
```

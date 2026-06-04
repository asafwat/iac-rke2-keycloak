# Install — per-OS commands

Copy-paste blocks for installing every required tool on Windows 11, Ubuntu, and macOS. Linked from [`../README.md`](../README.md#prerequisites).

Common to both IaC paths: VirtualBox, Vagrant, kubectl, Helm, git.
Path A adds: Terraform.
Path B adds: Go (1.22+) and Pulumi CLI (3.140+).

## Windows 11 — winget

Run PowerShell as Administrator.

```powershell
winget install --id=Git.Git -e
winget install --id=Oracle.VirtualBox -e
winget install --id=Hashicorp.Vagrant -e
winget install --id=Kubernetes.kubectl -e
winget install --id=Helm.Helm -e
winget install --id=Hashicorp.Terraform -e   # Path A only
winget install --id=GoLang.Go -e             # Path B only
winget install --id=Pulumi.Pulumi -e         # Path B only

# Close + reopen PowerShell so PATH refreshes, then verify
git --version; VBoxManage --version; vagrant --version
kubectl version --client; helm version --short
terraform version    # Path A
go version           # Path B
pulumi version       # Path B
```

### Hyper-V conflict — MUST be off

VirtualBox cannot run while Hyper-V is enabled (they fight over the hardware-virtualization interfaces). Check + disable via:

```powershell
# As Administrator
bcdedit /enum | findstr hypervisorlaunchtype                  # check current state
bcdedit /set hypervisorlaunchtype off                         # disable; requires reboot
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All   # full uninstall, also requires reboot
```

WSL2 and Docker Desktop both rely on Hyper-V — disabling it disables them too. Re-enable with `bcdedit /set hypervisorlaunchtype auto` when you're done with the lab.

### Running PowerShell scripts on Windows

Windows blocks unsigned PowerShell scripts by default. The bootstrap and init scripts in this repo are local files (not downloaded), so they're safe to run. Use the per-invocation bypass:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\ps\bootstrap.ps1
```

No system-wide policy change required. Alternatively, for an interactive session: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` (reverts on shell close).

## Ubuntu 22.04 / 24.04

```bash
# Baseline + common deps
sudo apt update
sudo apt install -y curl gnupg lsb-release apt-transport-https ca-certificates git

# VirtualBox (Oracle repo, current versions)
wget -qO- https://www.virtualbox.org/download/oracle_vbox_2016.asc | sudo gpg --dearmor -o /usr/share/keyrings/oracle-virtualbox.gpg
echo "deb [signed-by=/usr/share/keyrings/oracle-virtualbox.gpg] https://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib" | sudo tee /etc/apt/sources.list.d/virtualbox.list
sudo apt update && sudo apt install -y virtualbox-7.0

# Vagrant + Terraform (HashiCorp repo)
wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y vagrant terraform           # terraform is Path A only

# kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /usr/share/keyrings/kubernetes.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update && sudo apt install -y kubectl

# Helm
curl -fsSL https://baltocdn.com/helm/signing.asc | sudo gpg --dearmor -o /usr/share/keyrings/helm.gpg
echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm.list
sudo apt update && sudo apt install -y helm

# Path B only — Go + Pulumi
sudo apt install -y golang-go                                       # ensure 1.22+, otherwise grab from go.dev/dl
curl -fsSL https://get.pulumi.com | sh
echo 'export PATH=$PATH:$HOME/.pulumi/bin' >> ~/.bashrc && source ~/.bashrc
```

## macOS — Homebrew

```bash
brew install --cask virtualbox vagrant
brew install kubectl helm git
brew install terraform                                              # Path A only
brew install go pulumi/tap/pulumi                                   # Path B only
```

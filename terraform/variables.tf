variable "vm_box" {
  description = "Vagrant box image. Default openSUSE Leap 15.6 (vendor-aligned with Rancher/RKE2). Fallback: ubuntu/jammy64."
  type        = string
  default     = "opensuse/Leap-15.6.x86_64"
}

variable "vm_memory_mb" {
  description = "VM memory in MB. 12288 recommended for the full stack incl. monitoring; 10240 is tight (control-plane probes flake under load); 8192 works without monitoring."
  type        = number
  default     = 12288
}

variable "vm_cpus" {
  description = "VM vCPU count. 8 keeps the control-plane static pods stable under bootstrap load; 6 caused kube-scheduler/controller-manager liveness probe timeouts and crashloops; 4 works without monitoring."
  type        = number
  default     = 8
}

variable "vm_ip" {
  description = "Private-network IP. Must sit within VirtualBox's host-only allowed range (default 192.168.56.0/21)."
  type        = string
  default     = "192.168.56.10"
}

variable "vm_hostname" {
  description = "VM hostname; also used as the VirtualBox display name."
  type        = string
  default     = "rke2-server-1"
}

variable "argocd_chart_version" {
  description = "argo/argo-cd Helm chart version. Pinned for reproducibility."
  type        = string
  default     = "9.5.17"
}
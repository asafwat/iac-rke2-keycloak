output "vm_ip" {
  description = "Private IP of the VM."
  value       = var.vm_ip
}

output "vm_ssh_command" {
  description = "Convenience: how to SSH into the VM."
  value       = "cd ${local.repo_root} && vagrant ssh"
}

output "kubeconfig_path" {
  description = "Absolute path to the cluster kubeconfig. Server URL is rewritten to the VM IP so it works from the host. Set KUBECONFIG to this path - see README for per-OS commands."
  value       = "${local.repo_root}/kubeconfig"
}

output "argocd_port_forward" {
  description = "Command to expose ArgoCD UI on https://localhost:8080"
  value       = "kubectl -n argocd port-forward svc/argocd-server 8080:443"
}

output "argocd_admin_password_cmd" {
  description = "Command to retrieve the initial admin password (one-time use; change after first login)."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
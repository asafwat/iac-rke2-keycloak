# HA mode — production IaC pipeline + Ansible pattern

> **Important note for reviewers.** The current implementation using Vagrant
> + VirtualBox is strictly an **isolated local Desktop Proof of Concept (PoC)**.
> The single-VM Vagrant provisioner is a convenience for the lab
> assessment — it keeps the reviewer flow to one command and zero cloud
> dependencies. The production path described below replaces Vagrant
> entirely; the IaC layer keeps Terraform, but its provider plugs into a real
> hypervisor / cloud and Ansible takes over OS-level orchestration.
>
> For the storage pivot (Longhorn + external MinIO) and other application-
> layer changes that ride on top of this HA topology, see
> [`production-gaps.md`](production-gaps.md).

## Why Vagrant is wrong for production

`vagrant up` is great for a self-contained PoC: one binary on the host
provisions a VM, runs an inline shell provisioner, and shells out to
`VBoxManage`. It is **not** an enterprise provisioning tool — no
hypervisor-level integrations, no inventory, no node lifecycle beyond
"destroy and recreate," no awareness of network segmentation, no concept
of bare-metal targets. For HA RKE2 in production we drop the Vagrant
provider and target real infrastructure.

## Production IaC pipeline

The production workflow decouples the **infrastructure provisioning**
layer from the **software configuration** layer into a modular,
multi-tool pipeline:

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌───────────────────┐
│  Terraform  │ ──► │  cloud-init  │ ──► │   Ansible    │ ──► │  GitOps (ArgoCD) │
├─────────────┤     ├──────────────┤     ├──────────────┤     ├───────────────────┤
│ Enterprise  │     │ First-boot   │     │ OS harden    │     │ Workloads +       │
│ VMs +       │     │ network +    │     │ + RKE2 multi │     │ Longhorn config + │
│ networks    │     │ SSH keys +   │     │ -node bootstrap   │ │ S3 backup target  │
│             │     │ host profile │     │              │     │                   │
└─────────────┘     └──────────────┘     └──────────────┘     └───────────────────┘
```

### Layer 1 — Infrastructure (Terraform, real providers)

Terraform stays. Only the **provider** swaps:

| Substrate | Terraform provider | Typical environment |
|---|---|---|
| **On-prem virtualization** | `vsphere`, `harvester`, `proxmox`, `xenserver` | VMware vSphere, SUSE Harvester (HCI built on Kubernetes), Proxmox, KVM |
| **Bare metal** | `metal3`, `tinkerbell`, `equinix` | Metal³ (Kubernetes-native bare-metal lifecycle), Tinkerbell, Equinix Metal |
| **Public cloud** | `aws`, `google`, `azurerm`, `oci` | EC2 + VPC, GCE + VPC, Azure VM + VNet, OCI Compute |
| **Sovereign cloud** | provider for the local stack (G42, etc.) | UAE-resident infrastructure for local deployments |

The Terraform module structure stays the same — `terraform/main.tf`
declares VMs, the network, the load-balancer object, and outputs. Only
the resource types change (`vsphere_virtual_machine` instead of
`null_resource` + `vagrant up`). Variables like `ha_mode`,
`control_plane_count`, `worker_count`, `vm_memory_gb`, `disk_class`
become first-class inputs.

### Layer 2 — OS bootstrap (cloud-init)

`cloud-init` is the OS-side hook that runs at first boot. It is supported
by every serious cloud + most enterprise hypervisors (vSphere via
guestinfo, Harvester natively, AWS/GCP/Azure natively). What it does at
this stage:

- Set hostname, DNS, NTP
- Inject SSH public keys (the same key the Ansible controller uses)
- Configure static network for non-DHCP environments
- Optionally pre-install minimal packages (`open-iscsi`, `nfs-utils`,
  `iptables`) so Ansible has less work to do
- Disable swap, load kernel modules (`br_netfilter`, `overlay`), set
  basic sysctls — equivalent to the current Vagrant `[prep]` block

cloud-init is fired by Terraform via `user_data` (or the vendor's
equivalent attribute). After the VM finishes its first boot it's an SSH
target ready for Ansible.

### Layer 3 — Cluster bootstrap (Ansible)

Ansible's strength is **ordered remote operations across multiple hosts**,
which is exactly what HA RKE2 requires. Sequencing:

```
Phase A — install RKE2 server on rke2-server-1:
    /etc/rancher/rke2/config.yaml:
        write-kubeconfig-mode: "0644"
        tls-san: [<server-1 IP>, <LB IP>, <cluster DNS>]
        token: <vault-managed cluster token>
    systemctl enable --now rke2-server
    wait for /etc/rancher/rke2/rke2.yaml + node Ready

Phase B — fetch node token from server-1, register it in the inventory

Phase C — install RKE2 server on server-2 + server-3 (in parallel,
          both joining server-1):
    /etc/rancher/rke2/config.yaml:
        server: https://<server-1>:9345
        token: <copied from phase B>
        tls-san: same as server-1
    systemctl enable --now rke2-server
    wait for node Ready

Phase D — install RKE2 agent (workload) on each worker node:
    /etc/rancher/rke2/config.yaml:
        server: https://<LB IP>:9345
        token: <agent token>
    systemctl enable --now rke2-agent

Phase E — configure external LB (HAProxy / keepalived, or program a
          hardware/cloud LB via its provider) to front the three
          control-plane nodes on 6443 (kube-apiserver) + 9345 (registration)

Phase F — rewrite kubeconfig to point at the LB endpoint and copy to
          the operator workstation / CI artifact store
```

Ansible roles are deliberately thin — each ~50 lines. The single-node
Vagrant shell provisioner becomes the body of the `rke2-server` role's
`tasks/main.yml`, parameterized with the `server` URL + `token` for
nodes 2 and 3.

### Layer 4 — Workloads (GitOps via ArgoCD/FluxCD)

Once the cluster is up, the existing `argocd/` + `charts/` + `manifests/`
tree from this repo applies unchanged. ArgoCD reconciles all platform
components from Git exactly as it does today.

## HA cluster topology

```
                       External clients
                            │
                            │  (DNS round-robin / cloud LB / VRRP VIP)
                            ▼
              ┌───────────────────────────┐
              │ External Load Balancer    │  ← HAProxy + keepalived,
              │ kube-apiserver:6443       │     hardware LB (F5/A10),
              │ rke2-register:9345        │     or cloud-native NLB
              └─────────────┬─────────────┘
                            │
              ┌─────────────┼─────────────┐
              ▼             ▼             ▼
      ┌──────────────┬──────────────┬──────────────┐
      │ control-1    │ control-2    │ control-3    │  ← Ansible: rke2-server role
      │ etcd member  │ etcd member  │ etcd member  │     three control-plane nodes
      │ apiserver    │ apiserver    │ apiserver    │     no application workloads
      │ controller   │ controller   │ controller   │     (taint: node-role.kubernetes.io/control-plane=:NoSchedule)
      │ scheduler    │ scheduler    │ scheduler    │
      └──────────────┴──────────────┴──────────────┘
                            ▲
                            │  agent registration via LB:9345
                            │
      ┌──────────────┬──────────────┬──────────────┐
      │ worker-1     │ worker-2     │ worker-N     │  ← Ansible: rke2-agent role
      │ kubelet      │ kubelet      │ kubelet      │     stateful + stateless
      │ workloads    │ workloads    │ workloads    │     workloads (labels/taints
      │ Longhorn     │ Longhorn     │ Longhorn     │     to split GPU / monitoring /
      │ replicas    │ replicas     │ replicas     │     general-purpose tiers)
      └──────────────┴──────────────┴──────────────┘
                            │
                            ▼  S3 (etcd snapshots + Longhorn backups)
              ┌───────────────────────────┐
              │ External MinIO            │  ← off-cluster S3-compatible
              │ (dedicated VMs / hardware)│     target on a separate failure
              │ buckets: rke2-etcd,       │     domain from the cluster
              │ longhorn-vol, cnpg-bk     │
              └───────────────────────────┘
```

### Why a 3-node control plane

- **etcd quorum**. RKE2's embedded etcd needs an odd number of members
  to maintain quorum. 3 is the smallest safe number (tolerates 1 failure).
- **API availability**. With 3 apiserver instances, planned maintenance
  on one node doesn't drop the cluster's control plane.
- **Topology spread**. Each control-plane VM lands in a different fault
  domain — different ESXi host (vSphere), different rack (bare metal),
  different AZ (cloud).

### Why control-plane isolation

Production rule: **no application workloads on control-plane nodes.**
etcd is latency-sensitive and noisy-neighbor workloads on the same host
can blow apiserver SLOs. Enforced via the
`node-role.kubernetes.io/control-plane=:NoSchedule` taint on all three
servers; workload pods need explicit tolerations to land there (and we
don't grant them).

### Why external load balancer

The kube-apiserver and RKE2 registration port (9345) need a single
endpoint clients (kubelet on workers, ArgoCD, operators, humans) talk
to. Options:

| Option | When |
|---|---|
| **HAProxy + keepalived (VRRP VIP)** | Standard on-prem L4 LB. Two LB VMs, active/passive via VRRP. Production-grade for any network that supports VRRP multicast. |
| **Hardware LB** (F5 BIG-IP, A10, Citrix ADC) | Org already runs an LB pair — just register the three apiservers as a pool. No extra VMs. |
| **Cloud-native LB** (ELB / GCP LB / Azure LB) | Public cloud deployments. Created by Terraform alongside the control-plane VMs. |
| **DNS round-robin** | Last resort. No health checking; failed nodes still receive traffic until TTL expires. |

For on-prem sovereign deployments, the answer is usually
**keepalived + HAProxy on 2 dedicated LB VMs**. Why two: VRRP needs at
least one peer for failover; a single LB VM is a SPOF that defeats the
HA cluster behind it.

> **Why this lab document says HAProxy alone for the PoC.** In a
> Vagrant-on-VirtualBox single-host network, VRRP multicast doesn't
> work cleanly across the host-only adapter, so the simpler "one
> HAProxy VM" was the documented stand-in. Production uses keepalived
> + 2 LBs as described above.

## How `ha_mode` flag would gate this

```hcl
variable "ha_mode" {
  description = "If true, build full HA RKE2 cluster via the production pipeline (vSphere/Harvester/cloud provider + cloud-init + Ansible). If false, build the single-node Vagrant PoC."
  type        = bool
  default     = false
}

variable "control_plane_count" {
  type    = number
  default = 3
}

variable "worker_count" {
  type    = number
  default = 3
}

# When ha_mode = false: existing Vagrant null_resource path (PoC default)
# When ha_mode = true:  vsphere_virtual_machine / harvester_virtualmachine
#                       resources + null_resource.ansible_bootstrap
```

The default stays single-VM Vagrant so the assessment flow remains
"clone + bootstrap." `terraform apply -var ha_mode=true` switches to
the production topology.

## Repo layout this would add

```
ansible/
├── inventory/
│   ├── group_vars/
│   │   ├── all.yml             # rke2-version, kubeconfig-mode, tls-san list
│   │   └── rke2_servers.yml    # control-plane-specific
│   └── hosts.yml               # populated by Terraform output
├── site.yml                    # playbook driving phases A-F above
└── roles/
    ├── os-hardening/           # swap, kernel modules, sysctls, audit
    │   └── tasks/main.yml
    ├── rke2-server/            # control plane install + join
    │   ├── tasks/main.yml
    │   ├── templates/config.yaml.j2
    │   └── handlers/main.yml
    ├── rke2-agent/             # worker install + join
    │   ├── tasks/main.yml
    │   └── templates/config.yaml.j2
    └── rke2-lb/                # HAProxy + keepalived on the LB VMs
        ├── tasks/main.yml
        └── templates/{haproxy.cfg.j2,keepalived.conf.j2}
```

## Implementation order

If I had the time budget for HA in the assessment window:

1. Pick a hypervisor target (Harvester is the most likely choice for a
   Rancher-aligned stack; vSphere is the most likely for an existing
   enterprise estate).
2. Swap `null_resource` + Vagrant for the corresponding Terraform
   provider; output the inventory file Ansible needs.
3. Author the Ansible roles above. Test each independently against a
   single VM before sequencing.
4. ArgoCD HA values: flip `redis-ha.enabled: true` + 2 replicas
   everywhere except the application-controller (sharded, not replicated).
5. CNPG: bump Cluster `instances: 2` → 3, anti-affinity per-zone.
6. Keycloak: add Infinispan cluster config (jgroups discovery via
   headless Service, sticky sessions at the LB), `instances: 2`.
7. Update `bootstrap.ps1`/`.sh` to pass `-var ha_mode=true` if a flag
   is set, and skip the Vagrant-specific waits.

## Why this is documented but NOT implemented in the assessment

Time tightness, and — more importantly — **the HA path replaces Vagrant
entirely**, which means it can't share the same provisioner code as the
PoC. The HA story works the same way at the **application layer**: ArgoCD
reconciles the same charts, just with replica counts > 1 on workloads
that support it. The substantive new work is the Terraform-provider
swap + Ansible roles + LB configuration, which is ~2-4 days of focused
work after the single-node baseline is solid.

The whole HA path is a Stretch goal precisely because the assessment is
about Keycloak deployed correctly with secure defaults, not about
demonstrating an enterprise multi-VM provisioning pipeline.

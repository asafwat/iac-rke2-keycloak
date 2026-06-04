# Autoscaling on on-prem Kubernetes

Linked from [`production-gaps.md`](production-gaps.md). The earlier note there said "out of scope for fixed-size on-prem cluster" — true for the single-VM PoC, but misleading as a general statement. On-prem K8s **does** autoscale; it just uses different machinery than AWS Karpenter.

## Two layers

| Layer | What it scales | Where it lives |
|---|---|---|
| **Pod-level** — HPA / VPA / KEDA | Replica count of existing workloads within current node capacity | K8s control plane; identical on cloud and on-prem |
| **Node-level** — cluster-autoscaler / Karpenter | Number of K8s nodes (and therefore total cluster capacity) | Infrastructure-aware; this is where cloud and on-prem diverge |

Pod-level autoscaling does most of the day-to-day work in production. Node-level autoscaling handles trends and growth.

## Cloud — the AWS-Karpenter happy path

| Mechanism | Notes |
|---|---|
| **Karpenter** | AWS-first. Watches pending pods → spins EC2 directly (no ASG/MachineDeployment intermediary). Reacts in ~30 seconds. Integrates with spot, instance-type diversification, and consolidation/bin-packing. The current production standard on AWS. |
| **GKE Autopilot / Cluster Autoscaler with managed instance groups** | GCP equivalent — autopilot is fully managed, classic CA works with GCE MIGs. |
| **Azure AKS Cluster Autoscaler** | Backed by Virtual Machine Scale Sets. |

These work because EC2/GCE/Azure VM provisioning is API-driven, fast (seconds-to-minutes), and the cloud provides automatic VM-image baking and bootstrap.

## On-prem — Cluster API + cluster-autoscaler

The modern on-prem standard is **Cluster API (CAPI)** + the upstream **`cluster-autoscaler`** project. The chain:

```
   cluster-autoscaler                    CAPI provider                substrate
─────────────────────────       ─────────────────────────       ─────────────────────────
 watches pending pods    ─►     adjusts MachineDeployment   ─►   creates/destroys VMs or
 calculates demand               replica count                   bare-metal nodes via
                                                                 substrate's native API
```

CAPI's CRD model mirrors the Deployment → ReplicaSet → Pod chain, but at the node layer:

| CAPI CR | K8s analogue | Role |
|---|---|---|
| `Cluster` | — | The target K8s cluster definition |
| `MachineDeployment` | `Deployment` | A pool of VM nodes with rolling-update semantics |
| `MachineSet` | `ReplicaSet` | The replica controller |
| `Machine` | `Pod` | One VM/node |
| `MachineHealthCheck` | — | Remediation when a node goes unhealthy |

`cluster-autoscaler` recognizes MachineDeployments natively (via CAPI integration) and bumps their replica count when pods are pending.

## Providers per substrate

| Substrate | CAPI provider | Maturity / notes |
|---|---|---|
| **VMware vSphere** | **CAPV** (`cluster-api-provider-vsphere`) | Production-grade, widely deployed. Uses a vSphere VM template; new Machines are template clones. Provisioning latency: ~3-5 min per node. |
| **SUSE Harvester** | **CAPH** (`cluster-api-provider-harvester`) | Harvester is SUSE's HCI built on Kubernetes + KubeVirt. CAPH plugs into Rancher's Provisioning v2. |
| **Proxmox VE** | **CAPMOX** | Community provider; works for homelab / SMB |
| **Nutanix AHV** | **CAPX** | Vendor-supported by Nutanix |
| **OpenStack** | **CAPO** | Most mature non-cloud CAPI provider |
| **Bare metal (PXE/IPMI/Redfish)** | **Metal³** (Ironic-based) | Production-grade for bare-metal-at-scale; provisioning takes 10-15 min per node |
| **Bare metal (alternative)** | **Tinkerbell** | Newer, k8s-native; CAPT bindings emerging |
| **Equinix Metal / SaaS bare metal** | **CAPP** | API-driven bare metal, fast (~minutes) |

## RKE2 + Rancher specifically

**Rancher Provisioning v2** (the current default for managing downstream clusters) is **built on CAPI**. So an RKE2 cluster registered with Rancher gets, for free:

- CAPI `MachineDeployment` per node pool (control-plane, worker, GPU, monitoring tier — separate pools per intended workload class)
- `cluster-autoscaler` drives the MachineDeployment replica count
- Provider-specific CAPI provider creates/destroys VMs on the underlying substrate
- New VMs auto-join the RKE2 cluster via the bootstrap token RKE2 already manages

So if this lab's RKE2 cluster ran against **Harvester** instead of Vagrant, the production autoscaling story would be:

```
Rancher  →  CAPH  →  Harvester VMs (KubeVirt)  →  RKE2 join
                ▲
                │
       cluster-autoscaler
```

Declared once. Scales workers from N to M based on pending pods. The application layer (this repo's `argocd/` + `charts/`) doesn't know or care.

## Karpenter on-prem?

Karpenter is **still AWS-first in 2026**. Emerging work for on-prem:

- `karpenter-aws` → reference implementation
- Karpenter providers for CAPI / Kwok / Cluster API generic exist but are not GA
- Some vendors (e.g., Rancher) are integrating Karpenter-style behavior into their existing CAPI-driven autoscaler

**The reason Karpenter is interesting on AWS** — sub-minute EC2 provisioning + spot integration + bin-packing optimization — **doesn't translate cleanly to on-prem** where VM creation is inherently slower (template clone, OS bootstrap, RKE2 join) and there's no spot market. The on-prem equivalent of "Karpenter convenience" is **CAPI + a good provider + reasonable VM template caching**. Not as elegant, but solves the same problem.

## Pod-level autoscaling — the more impactful lever

For most on-prem deployments, **pod-level autoscaling does more work than node-level**. Fleet size is typically stable (because adding a vSphere VM takes 3-5 minutes, not 30 seconds like EC2), and most elastic behavior lives at the pod layer:

| Mechanism | Best for |
|---|---|
| **HPA** (Horizontal Pod Autoscaler) | CPU / memory-driven; the K8s standard. Scales Deployments/StatefulSets. |
| **KEDA** (Kubernetes Event-Driven Autoscaler) | Event-driven scaling on Kafka lag, queue depth, Prometheus metrics, cron schedules. Extremely popular on-prem for Kubeflow / MLOps / async-processing workloads. Includes **scale-to-zero**. |
| **VPA** (Vertical Pod Autoscaler) | Vertical scaling (request/limit raise) for stateful workloads where horizontal scaling isn't trivial. |

## Practical posture for typical on-prem at scale

1. **Right-size the cluster for steady-state** with ~20-30% headroom.
2. **Pod-level autoscaling (HPA + KEDA)** handles minute-by-minute load.
3. **Node-level autoscaling via CAPI** handles hour-plus trends + organic growth.
4. **Manual node-pool resize** for major capacity changes — still very common; IT capacity planning is monthly/quarterly on-prem in most orgs.

The biggest practical difference vs. cloud: **provisioning latency**. Spinning a vSphere worker takes 3-5 min; EC2 with Karpenter is ~30 seconds. So on-prem autoscaling tunes for slower reactions:
- Bigger fleet headroom
- Earlier triggers (autoscale before you actually need capacity, not at the moment of need)
- More conservative scale-down (keep nodes around longer to absorb the next spike)

## Summary

- Pod-level autoscaling (HPA / VPA / KEDA) is **identical on cloud and on-prem**, and does most of the work everywhere.
- Node-level autoscaling on-prem uses **Cluster API + cluster-autoscaler** with a substrate-matched provider — same outcome as Karpenter on AWS, slower provisioning, different controller chain.
- For RKE2 specifically, **Rancher Provisioning v2** is CAPI under the hood. The production HA path documented in [`ha-pattern.md`](ha-pattern.md) drops directly into this story — adopt Rancher Manager + a CAPI provider matching the substrate (CAPV / CAPH / CAPMOX / Metal³) and you get autoscaling without changing the application layer.

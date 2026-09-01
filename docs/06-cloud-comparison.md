# Azure and OpenStack compared

**Worth 4 points (I1)** — *"Usporedba ponude Azure i OpenStack elemenata"*.

TechSprint's actual question is "which provider should we use", so the section
should end with an answer rather than a feature list.

---

## Element-by-element

| Element | Azure | OpenStack | Which is better here |
|---|---|---|---|
| Isolation boundary | Resource group inside a subscription | Keystone **project** (tenant) | **OpenStack.** A project scopes quotas, networks, images and volumes, and a user with no role cannot even get a token for it. A resource group scopes only RBAC |
| Virtual network | VNet, regional | Neutron network, project-scoped | Tie. Azure gives implicit routing; Neutron makes you build the router, which teaches more |
| Router | Implicit system routes | Explicit `openstack router create` | **Azure** for convenience, **OpenStack** for transparency |
| Firewall | NSG: ordered rules with platform default-deny, subnet- or NIC-scoped | Security group: allow-only, port-scoped | **Azure.** The effective rule list makes the decision visible |
| Group-based firewall rules | Application Security Group | `remote_group_id` on a rule | Tie — same idea, different syntax |
| Outbound internet | NAT Gateway, or a controlled NVA; this project uses the jump/NVA | Router SNAT on the external gateway | **Azure** at scale; OpenStack is simpler in this small topology |
| Public ingress | Public IP resource on a NIC | Floating IP, DNAT at the router | Tie. The floating IP's DNAT confuses newcomers; the Azure model is more literal |
| Load balancer | Standard LB and Application Gateway, both managed | Octavia Amphora and OVN are present in this lab | **Azure** for lower operational variance; Amphora provides equivalent health monitoring here |
| Object storage | Blob: tiers, lifecycle policies, managed identity | Swift: project-scoped containers mounted with rclone | **Azure.** Managed identity removes the guest object-storage secret |
| File storage | Azure Files (SMB/NFS), managed | Manila native CephFS backed by Ceph | Tie for this lab; both are managed file services |
| Block storage | Managed disks, four performance tiers | Cinder volumes, tier depends on the backend | **Azure** for predictable, documented tiers |
| Delegated storage access | managed identity on one Blob container; separate Files-account key | dedicated Swift identity with project-only `swiftoperator`; per-share CephX key | **Azure** removes the BlobFuse secret; OpenStack gives stronger project isolation |
| Identity | CSV service principals and a **custom role** | SQL-backed CSV users, groups, roles from `policy.yaml` | **Azure** for role granularity; OpenStack for tenant boundaries |
| Least-privilege VM control | Custom role with only power and read actions | No built-in role between `reader` and `member`; needs an operator-level policy override | **Azure**, and it directly affects the grade |
| RBAC inheritance | Inherits down the scope hierarchy | No inheritance by default | **Azure.** This project still assigns the lead per TechSprint resource group to avoid unrelated subscription access |
| Monitoring | Azure Monitor, metric alerts, KQL, agent optional | Ceilometer/Gnocchi, usually not exposed to students | **Azure.** The clearest managed-service advantage encountered |
| IaC | Terraform (azurerm), Bicep, ARM | Terraform (openstack provider), Heat, Ansible | Tie. Both are first-class in Terraform |
| Cost model | Consumption billing, per-resource meters | Project quota; no price signal at all | Depends — see below |
| Failure diagnostics | Specific API errors, `az vm run-command` via the guest agent | `No valid host was found` for several distinct causes | **Azure.** Better error messages saved real time |

## The differences that actually shaped this project

**1. Keystone projects beat resource groups for isolation.** This is
OpenStack's clear win. The brief's hardest requirement is that developers must
not control or reach each other. Keystone refuses to issue Mario a token scoped
to Andrija's project, while disjoint Neutron networks and security groups block
the packet path. On Azure, the equivalent controls are resource-group RBAC plus
non-transitive hub-and-spoke peering and NSGs.

**2. Azure RBAC beats Keystone roles for least privilege.** The mirror image.
*"Programeri moraju moći pokrenuti, ugasiti i ponovno pokrenuti isključivo svoje
VM-ove"* maps onto an Azure custom role with power-state and read actions. OpenStack has no
equivalent without editing Nova's `policy.yaml` on the controllers, which a
tenant on a shared lab cannot do. So the same requirement is met two different
ways: a narrow role on Azure, a hard boundary on OpenStack.

**3. Private-cloud managed services must be discovered.** Azure's load-balancer
and file-share APIs are standard subscription services. The Academy cloud had
to be inspected before implementation; that inspection proved Octavia, Swift
and CephFS-backed Manila were available. The difference is operator-selected
capability, not an absence of those services in this lab.

**4. Cost is visible on one side and invisible on the other.** Azure itemises
every meter, so the estimate in [15-cost-estimate.md](15-cost-estimate.md) is
grounded in real numbers. The OpenStack lab presented a quota and no prices at
all — which is not free, only unpriced. A private cloud's cost is capital
expenditure plus staff, and it does not appear in any API.

## Same requirement, two implementations

Useful as a single table in the report, because it shows the mapping is
deliberate rather than accidental:

| Brief requirement | Azure | OpenStack |
|---|---|---|
| Isolated environment per developer | Resource group + VNet, spoke of a hub | Keystone project + Neutron network |
| No inter-developer traffic | Non-transitive peering + default-deny NSG/NVA | Disjoint networks; RBAC shares each only with management; security-group deny |
| Jump host is the only entry | One public IP, in the hub | One floating IP, in the mgmt project |
| Two Moodle instances | 2 × `azurerm_linux_virtual_machine` | 2 × `openstack_compute_instance_v2` |
| Load balancer | Standard LB, internal | Octavia Amphora `SINGLE` |
| 2 vCPU / 4 GB | `Standard_B2s` | flavor with vcpus=2, ram=4096 |
| Two disks | `os_disk` + `azurerm_managed_disk` | boot volume + Cinder volume |
| Object storage | Blob container | Swift container |
| File storage | Azure Files share | Manila native CephFS |
| Least-privilege storage | container-scoped managed identity for Blob; isolated Files key | Swift-only service identity; unique CephX share key |
| Power control, own VMs only | Custom role at resource-group scope | `member` in own project only |
| Lead controls every VM | Custom power role on every TechSprint resource group | `member` in every project |
| Users from CSV | Entra service principals (lecturer-approved tenant fallback) | Keystone users + groups |
| Internet egress | jump/NVA source NAT | Router SNAT |

## Recommendation for TechSprint

For **this** workload — short-lived, isolated, per-developer test environments
that are idle most of the time — **Azure**, for three reasons that are about
operations rather than technology:

1. **The public-cloud service contract is predictable.** This Academy deployment
   has every required OpenStack service, but that was known only after catalog,
   backend and provider discovery. Azure subscriptions expose a more consistent
   baseline across environments.
2. **Least privilege is expressible.** The custom power-operator role is exactly
   the requested permission. On OpenStack, granting it needs cloud-operator
   access to the controllers.
3. **Environments are disposable and billed by the hour.** A test environment
   that exists for two days should cost two days. A private cloud's cost is
   already sunk, so idle capacity is free — but so is *unavailable* capacity
   when the quota is full, and a developer blocked on quota is expensive.

**When the answer flips.** OpenStack wins on steady, predictable, high
utilisation; where data residency or existing hardware forces it; or at a scale
where per-hour billing exceeds the amortised cost of owning the machines. If
TechSprint's test environments became long-running production-like stacks with
constant load, the calculation inverts.

**The honest hybrid answer**, and the one worth ending on: the two are not
mutually exclusive. This project deploys the same architecture to both from one
CSV, which is itself the argument — the abstraction that matters is the
*definition* of the environment, not the provider running it. TechSprint could
run steady-state internal environments on OpenStack and burst to Azure, because
the deployment code already targets either.

---

Previous: [Design decisions](05-design-decisions.md) ·
Next: [Azure networking explained](09-azure-network.md)

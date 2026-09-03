# Azure and OpenStack compared

**Worth 4 points (I1)** — *"Usporedba ponude Azure i OpenStack elemenata"*.

TechSprint's actual question is "which provider should we use", so the section
should end with an answer rather than a feature list. The
[known limitations](#known-limitations) of the chosen design are at the end of
this document, because the comparison is only credible next to the compromises.

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
every meter, so the estimate in [cost-estimate.md](cost-estimate.md) is
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

# Known limitations

Every deliberate compromise, with what it would take to fix. Include this in the
report: an assessor who finds a weakness you have already named and costed reads
it as judgement. One they find that you have not reads as an oversight.

## 1. The database is a single point of failure

**What.** Node 1 runs MariaDB; node 2 connects to it. If node 1 dies, both
Moodle instances stop working, so the "high availability" is only at the web
tier.

**Why.** A managed database — Azure Database for MySQL Flexible Server, the
architecturally correct answer — costs roughly 25 EUR/month per developer on the
smallest burstable tier. For two developers that is 50 EUR/month against a 100
EUR total grant. Galera clustering on the two app nodes would need a third node
for quorum, and two-node Galera is worse than a single database because it
split-brains.

**Fix, in order of preference:**

1. Azure Database for MySQL Flexible Server per developer, `Standard_B1ms`,
   private endpoint into the app subnet. Terraform: `azurerm_mysql_flexible_server`.
2. A three-node Galera cluster, so the third node provides quorum.
3. MariaDB primary/replica with automated failover, which needs a proxy layer.

**Where it shows.** `ansible/roles/database/tasks/main.yml` — `is_db_primary`
selects node 1.

## 2. Session affinity, not shared sessions

**What.** Moodle keeps session state on the node that created it. The load
balancer pins each client to one backend by source IP. If that node fails, users
pinned to it are logged out even though the other node is healthy.

**Why.** Externalising sessions needs Redis (Azure Cache for Redis: ~16
EUR/month per developer) or a shared database session handler, which puts more
load on the single database above.

**Fix.** Azure Cache for Redis, or `$CFG->session_handler_class =
'\core\session\redis'` against a Redis instance in the app subnet. On OpenStack,
Redis on a third instance.

**Consequence to note:** source-IP affinity also degrades when many users share
one NAT address — an entire campus network would pin to a single backend.

**Where it shows.** `load_distribution = "SourceIP"` in the Azure LB rule and
`lb_method = "SOURCE_IP"` in Octavia.

## 3. HTTP, not HTTPS

**What.** Moodle is served over plain HTTP. Credentials cross the network
unencrypted.

**Why.** The load balancer is internal and reached only through an SSH tunnel,
so traffic is encrypted between the workstation and the bastion. Inside the VNet
it is plaintext. A public HTTPS endpoint would need an Application Gateway
(~125 EUR/month per developer) or certificate management on each node, and a
public endpoint contradicts the brief's own "no public access except the jump
host" requirement.

**Honest assessment:** this is the design's weakest security property. The SSH
tunnel makes it defensible for an isolated test environment, not for anything
real.

**Fix.** Application Gateway with a managed certificate, or Let's Encrypt on each
node with `certbot` plus a public DNS name — which again requires a public
endpoint the brief forbids.

## 4. Storage account key on disk for the file share

**What.** The Azure Files SMB mount uses the key of a dedicated file-only
StorageV2 account. It lives in `/etc/smbcredentials-techsprint`, mode `0600`,
root-owned.

**Why.** Azure Files identity-based SMB requires domain/Kerberos tooling that
has not been validated on the selected Rocky image. Separating accounts keeps
the SMB key from accessing the managed-identity-protected Blob account.

**Fix.** Azure Files identity-based SMB, or NFS 4.1 with a private endpoint.

**Do not claim** a fully keyless design. Naming this exception is what makes the
managed-identity claim credible.

## 5. No power-state-only role on OpenStack

**What.** Azure has a custom role granting exactly start, restart and
deallocate. OpenStack's `member` role also permits create and delete; `reader`
permits neither start nor stop; there is nothing between them.

**Why.** Narrowing it means editing Nova's `policy.yaml` on the controllers,
which a tenant on a shared academy lab cannot do.

**Fix, if you control the deployment:**

```yaml
# /etc/nova/policy.yaml
"os_compute_api:servers:delete": "role:admin"
"os_compute_api:servers:create": "role:admin"
"os_compute_api:servers:start":  "role:member"
"os_compute_api:servers:stop":   "role:member"
```

**What holds instead.** The requirement's *intent* — a developer cannot touch
anyone else's VMs — is enforced by the project boundary, which is stronger than
Azure's. A developer can delete their own instance, which the brief does not ask
to prevent. Full discussion in
[diagrams/openstack-iam.md](diagrams/openstack-iam.md).

## 6. Terraform state is local

**What.** `terraform.tfstate` sits on your workstation. It holds resource ids and
the generated passwords.

**Why.** A remote backend needs a storage account that exists before Terraform
runs — a bootstrapping problem not worth solving for a semester project.

**Consequences:** lose the file and Terraform will try to recreate everything;
two people applying concurrently corrupt each other's state; the file contains
secrets and must never be committed (it is gitignored).

**Fix.** An `azurerm` backend with blob leasing for locking. The commented-out
block in `iac/azure/main.tf` shows the shape.

## 7. Moodle is installed from a tarball at deploy time

**What.** Ansible downloads the Moodle release on every fresh node.

**Why.** Simple, and it always gets the current point release.

**Consequences:** the deployment depends on `packaging.moodle.org` being
reachable through the jump/NVA, adds 1–2 minutes per node, and two nodes
built weeks apart could get different point releases.

**Fix.** Build a golden image with Packer containing Rocky Linux plus Moodle plus
PHP, then boot from it. Deployment time drops to the VM provisioning time and the
version is pinned. This is also the right answer to the Heat template-size
problem noted in the OpenStack stack.

## 8. Multi-region compute, but region-local storage

**What.** Quota forces the two developer environments into Denmark East and
Austria East. Each environment still uses LRS storage: three replicas in one
regional datacentre. Its backups and object data remain in that same region.

**Why.** GRS increases storage cost for cross-region durability a disposable
test environment does not need.

**Fix.** `account_replication_type = "GRS"`, or Azure Backup with a Recovery
Services vault in a paired region.

## 9. Secrets in Terraform outputs

**What.** Generated passwords and the storage key appear in `terraform output
-json`, which `deploy.sh` writes to `build/<cloud>-output.json`.

**Mitigations in place:** the file is `chmod 600`, `build/` is gitignored, the
outputs are marked `sensitive` so they do not print by default, and deploy.sh
sets `umask 077` before creating any generated artifact.

**Fix.** Azure Key Vault with `azurerm_key_vault_secret`, and Ansible reading
from it at run time rather than from an inventory file. On OpenStack, Barbican.

## 10. No monitoring or alerting

**What.** Nothing watches these environments. A full disk or a dead Moodle is
noticed by a developer failing to load a page.

**Why.** Not in the brief, and the marks are elsewhere.

**Fix.** Azure Monitor Agent plus a Log Analytics workspace (5 GB/month free), a
metric alert on CPU and disk, and an action group emailing the lead. On
OpenStack, Prometheus with `node_exporter` on a management instance — the private
cloud has no managed equivalent, which is itself a comparison point.

## Summary table for the report

| # | Limitation | Reason | Cost to fix |
|---|---|---|---|
| 1 | Database is a single point of failure | ~25 EUR/mo per developer | Managed MySQL, or 3-node Galera |
| 2 | Session affinity instead of shared sessions | ~16 EUR/mo per developer | Redis session store |
| 3 | HTTP, not HTTPS | needs a public endpoint the brief forbids | App Gateway + certificate |
| 4 | Storage key on disk for SMB | simpler current implementation | managed-identity SMB with AzFilesAuthenticator |
| 5 | No power-only role on OpenStack | needs controller access | Nova `policy.yaml` override |
| 6 | Local Terraform state | bootstrapping | remote backend with locking |
| 7 | Moodle downloaded at deploy time | simplicity | golden image with Packer |
| 8 | Region-local LRS storage | cost | GRS, or Azure Backup |
| 9 | Secrets in Terraform outputs | no secret store provisioned | Key Vault / Barbican |
| 10 | No monitoring | out of scope | Azure Monitor / Prometheus |

None of these prevents the brief's requirements from being met. Items 1, 2 and 3
are the ones a production deployment would have to fix first, and 3 is the one
that would matter most.

---

Previous: [Architecture and design decisions](architecture.md) ·
Next: [Testing and evidence](testing-and-evidence.md)

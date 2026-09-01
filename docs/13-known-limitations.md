# Known limitations

Every deliberate compromise, with what it would take to fix. Include this in the
report: an assessor who finds a weakness you have already named and costed reads
it as judgement. One they find that you have not reads as an oversight.

---

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

---

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

Previous: [OpenStack lab discovery](10-openstack-discovery.md) ·
Next: [Testing and evidence](14-testing-and-evidence.md)

# Design decisions

**Worth 7 points (I1)** — the single largest scored item in the brief:
*"Objašnjenje odabira elemenata (Load balancer, Objektna/Datotečna pohrana, Tip
VM-a, Tip diska)"*.

Four decisions, each with what was chosen, what was rejected, and why. Copy the
structure into the report; the marks are for the reasoning, not the choice.

---

## 0. Azure for Students placement and egress

The subscription permits only six vCPUs per region. The official minimum needs
four 2-vCPU Moodle VMs plus a 1-vCPU lead/jump VM, so a single-region deployment
cannot fit. Region is not fixed by the brief, therefore the tested placement is:

| Region | Resources | Regional vCPUs |
|---|---|---|
| Denmark East | Mario's two `Standard_B2s` VMs + `Standard_A1_v2` jump/lead | 5 |
| Austria East | Andrija's two `Standard_D2ls_v6` VMs | 4 |

Both application sizes provide exactly 2 vCPU and 4 GB RAM. Global VNet peering
joins each isolated developer VNet to the central VNet; it does not create a
route between developers.

The rubric literally allows a public IP only on the jump host. Per-spoke NAT
Gateways were therefore rejected because each requires another public IP. Each
spoke instead has a default route to the jump VM, whose NIC has IP forwarding
enabled and whose `nftables` rule performs outbound-only source NAT. This is
cheaper and rubric-compatible, at the cost of making the jump VM an egress
single point of failure.

---

## 1. Load balancer

### Azure: Standard Load Balancer, internal

| Option | Layer | Cost/month | Verdict |
|---|---|---|---|
| **Standard Load Balancer, internal** | 4 (TCP) | ~18 EUR + data | **Chosen** |
| Application Gateway v2 | 7 (HTTP) | ~125 EUR + capacity units | Rejected: 5× the cost of everything else per developer |
| Basic Load Balancer | 4 | free | Rejected: retired September 2025, no SLA |
| nginx on a third VM | 7 | ~30 EUR (another B2s) | Rejected: another VM to patch, and it is a single point of failure |

**Internal, not public.** The brief forbids public access to anything but the
jump host, so a public frontend would contradict a graded requirement. Moodle is
reached through an SSH tunnel via the bastion. Detailed Azure LB versus
Application Gateway comparison, which the rubric asks for separately, is in
[08-azure-loadbalancer.md](08-azure-loadbalancer.md).

**Health probe on `/healthz.php`, not TCP:80.** A TCP probe only proves that
Apache accepted a connection. The HTTP endpoint returns 503 unless Moodle's
config, database, data disk, object mount and file mount are all available and
writable where required. Ansible configures those dependencies before running
the installer, so a node joins the pool only when it can serve Moodle safely.

**`load_distribution = "SourceIP"`.** Moodle keeps session state on the node
that created it unless sessions are externalised to Redis or the database. With
the default five-tuple distribution a user's requests alternate between nodes
and they are logged out on roughly every second click. Source-IP affinity pins
each client to one backend. The production fix is a shared session store; that
is out of scope here and recorded in
[13-known-limitations.md](13-known-limitations.md).

### OpenStack: Octavia Amphora `SINGLE`

The RHOSP 16.1 lab exposes both OVN and Amphora providers. OVN is lightweight
and consumes no guest VM, but this release does not implement health monitors.
The project therefore creates an Octavia flavor profile selecting Amphora
`SINGLE` with the existing 1-vCPU/1-GB `octavia_65` flavor. Each developer gets
one managed amphora and the same HTTP `/healthz.php` monitor used on Azure.

Placement discovery showed enough allocation capacity for four 4-GB application
VMs, the central jump and two 1-GB amphorae. This choice costs more lab capacity
than OVN but supports the failure detection needed for a defensible HA demo.

---

## 2. Object storage and file storage

The brief asks for **both**, per developer, both auto-mounted. They are not
interchangeable, and saying why is most of the marks.

| | Object storage | File storage |
|---|---|---|
| Azure | Blob container `moodle-files` | Azure Files share `moodle-backups` |
| OpenStack | Swift container | Manila native CephFS share |
| Access | BlobFuse2/rclone FUSE mount | SMB (Azure) / CephFS kernel client |
| Protocol | HTTP verbs | SMB (Azure) / NFS (OpenStack) |
| Good at | Cheap, effectively unlimited, versioned, lifecycle-managed | Random access, `tar`, existing tools that expect a path |
| Bad at | No partial writes, no locking, no rename | More expensive per GB, throughput limits, needs a mount |
| Used for | Moodle's uploaded files and resources | Backup archives |

**Why that split.** Moodle's file API is content-addressed — it stores files by
hash and rarely rewrites them in place — which is the application pattern most
compatible with an object-backed FUSE mount. BlobFuse2 presents the required
container at `/var/moodledata` on both Azure nodes. It runs with direct I/O and
writeback caching disabled so two mounts do not serve stale local cache data.
Blob storage still lacks full POSIX locking; this is acceptable only for the
small test deployment and is recorded as a limitation. Backups are the
opposite: `tar` needs a conventional path it can stream into and later read
back, so a mounted file share is the right tool.

**Least privilege, which is separately scored (2 points each side).**

On Azure, the Moodle nodes reach blob storage through a **user-assigned managed
identity** holding `Storage Blob Data Contributor` scoped to **one container** —
not the storage account. BlobFuse2 authenticates with that identity and mounts
the container automatically through systemd. No account key is present in the
BlobFuse configuration, and the identity cannot read the backup share.
`lib/verify.sh` asserts the authentication mode rather than trusting it:

```bash
check "I4" "blob configuration uses managed identity" \
  on_node "$ip" "grep -q 'mode: msi' /etc/blobfuse2-techsprint.yaml"
```

Blob and Files use separate accounts. The Files SMB key lives in a root-owned
mode-`0600` credential file, but cannot access the Blob account. Both accounts
deny network access by default and allow only the developer subnet plus the
deployment workstation while Terraform creates the container/share.

On OpenStack, each environment receives a dedicated `svc-...-swift` identity
with only `swiftoperator` in that developer project. Its credential is mode
`0600`, owned by the Apache account running the rclone mount, and cannot operate
Nova or another project. Manila creates a native CephFS share and a unique
CephX identity/key per environment.

---

## 3. VM type

The brief fixes the application size at 2 vCPU and 4 GB. SKU capabilities were
queried rather than inferred from names because student subscriptions expose a
restricted set in each region.

| Size | Region | vCPU | RAM | Notes |
|---|---|---|---|---|
| **Standard_B2s** | Denmark East | 2 | 4 GB | Chosen for developer 1; burstable and quota-compatible |
| **Standard_D2ls_v6** | Austria East | 2 | 4 GB | Chosen for developer 2; the available exact-fit SKU |
| **Standard_D2ls_v6** | Belgium Central | 2 | 4 GB | Reserved for the appended third-developer plan demonstration |
| **Standard_A1_v2** | Denmark East | 1 | 2 GB | Jump/lead VM; separate family keeps Denmark within quota |

**Why mixed SKUs.** A single SKU is aesthetically simpler but impossible under
the available regional capacity. Each developer remains internally consistent:
both of their nodes use the same shape. The application sees the required CPU
and memory in either region, while Terraform verifies the placement explicitly.

**The trade-off, which must be stated.** B-series accrue CPU credits when below
their baseline (B2s baseline is 40% of two cores) and spend them above it. Once
credits are exhausted, the VM is throttled to baseline — and `Percentage CPU`
still reads healthy while everything feels slow. This appears in practice during
Moodle's initial install, which is CPU-heavy for several minutes.

If your demo includes a load test, watch the credit metric, not just CPU:

```bash
az monitor metrics list --resource "$VM_ID" \
  --metric "CPU Credits Remaining" --interval PT1M --aggregation Average \
  --query "value[0].timeseries[0].data[-5:].{time:timeStamp, credits:average}" -o table
```

For a production Moodle serving real students, D2s_v3 or larger is correct
because the load is sustained rather than bursty. Saying that shows you
understand *why* the sizes differ rather than which is cheaper.

**Jump host: A1_v2.** It forwards SSH and low-volume package-download traffic.
Using the Av2 family avoids consuming the four B-family vCPUs reserved for the
Denmark developer environment.

**OpenStack:** pick the flavor whose actual vCPU and RAM match, not whose name
looks right. Flavor names are site-specific and frequently misleading:

```bash
openstack flavor list -f table
openstack flavor show m1.medium -c vcpus -c ram -c disk
# vcpus 2, ram 4096  <- verify, do not assume
```

`lib/verify.sh` checks `nproc` and `/proc/meminfo` on the running guest, so a
mismatched flavor fails the run rather than quietly losing the point.

---

## 4. Disk type

Two disks per VM, as required. They have different jobs and therefore different
answers.

| Disk | Purpose | Azure choice | Size | OpenStack choice |
|---|---|---|---|---|
| OS disk | Rocky Linux, Apache, PHP, Moodle code | StandardSSD_LRS | 64 GB | boot volume from image |
| Data disk | `/mnt/techsprint-data` — local cache and staging | StandardSSD_LRS | 32 GB | Cinder volume |

| Azure disk type | IOPS (small) | ~EUR/month (64 GB) | Verdict |
|---|---|---|---|
| Standard HDD | ~500 | ~2.50 | Rejected: latency makes Moodle's admin pages feel broken |
| **Standard SSD** | ~500 baseline, burst to 1000 | ~4.50 | **Chosen** |
| Premium SSD | 240 provisioned | ~9.00 | Rejected: 2× the price for IOPS this workload never reaches |
| Premium SSD v2 | configurable | ~10+ | Rejected: no free-tier benefit, more moving parts |

**Why Standard SSD.** Moodle is latency-sensitive on small random reads — every
page load touches many small PHP files and rows — and Standard HDD's ~10 ms
seek time is felt directly in the browser. Premium SSD's provisioned IOPS solve
a throughput problem this workload does not have. Standard SSD sits at the point
where the interface is fast enough and the bill is not.

**Why a separate data disk at all**, beyond the brief requiring two:

1. BlobFuse2's local cache and temporary backup staging cannot fill the OS disk.
2. It can be resized or rebuilt independently from the system disk.
3. It visibly satisfies and demonstrates the required second mounted disk while
   shared Moodle content remains in the object-storage mount.

**Mounted by UUID, with `nofail`** — both deliberate:

```
UUID=8f3a... /mnt/techsprint-data xfs defaults,nofail 0 2
```

Device names are not stable. Attach one more volume and yesterday's `/dev/sdc`
can become `/dev/sdd`, mounting the filesystem in the wrong place or not at all.
`nofail` means a missing volume degrades to a missing mount rather than dropping
the instance into emergency mode — where a cloud VM has no console to recover
from. The verifier checks the resulting mount.

**XFS over ext4.** Both work. XFS is the RHEL-family default, handles many small
files well, and supports online growth (`xfs_growfs`) after expanding the disk,
which is the realistic maintenance operation here.

---

## Decision summary for the report

| Decision | Chosen | Rejected | Deciding reason |
|---|---|---|---|
| Load balancer (Azure) | Standard LB, internal | Application Gateway | ~125 vs ~18 EUR/month; L7 features unused |
| Load balancer (OpenStack) | Amphora `SINGLE` | OVN | RHOSP 16.1 OVN has no health monitors |
| Health probe | HTTP `/healthz.php` | TCP:80 | HTTP verifies the configured web path and exposes node identity |
| Session handling | Source-IP affinity | round robin | Moodle keeps per-node session state |
| Object storage | Blob / Swift through FUSE | file share for everything | Matches Moodle's content-addressed file API |
| File storage | Azure Files / native CephFS | blob for everything | `tar` needs a conventional mounted path |
| Blob mount identity | Managed identity, one container | account key in BlobFuse | No long-lived secret in the Blob configuration |
| Azure storage layout | separate Blob and Files accounts | one shared account | SMB key cannot bypass Blob managed identity |
| Azure placement | Denmark + Austria | one region | Six-vCPU student quota cannot fit the nine-vCPU minimum |
| Outbound access | jump host as NVA/NAT | NAT Gateway per spoke | preserves the single-public-IP requirement |
| VM size | B2s + D2ls_v6 | one unavailable SKU everywhere | both selected sizes are exactly 2 vCPU / 4 GB |
| Disk type | Standard SSD | Premium SSD / Standard HDD | HDD latency is user-visible; Premium IOPS unused |
| Disk layout | separate cache/staging disk | single disk | Independent lifecycle; cache cannot wedge the OS |
| Mount method | UUID + `nofail` | device name | Device order is unstable; `nofail` avoids emergency mode |

---

Previous: [Naming and tagging](04-naming-and-tagging.md) ·
Next: [Azure and OpenStack comparison](06-cloud-comparison.md)

# Discovering the Red Hat Academy lab

Every OpenStack installation differs. The commands below remain the repeatable
discovery procedure, but the target CL110 RHOSP 16.1 lab was inspected on
26 August 2026 and no longer relies on hypothetical service fallbacks.

```bash
make openstack-discover
```

---

## Confirmed CL110 lab result

- Authentication: `admin@Default`, with system administration available.
- Identity: the Academy `Example` domain is externally backed; a bounded probe
  proved that a new `TechSprint` domain uses writable SQL identities.
- Image: `rhel8`; expected SSH user `cloud-user`, pending runtime confirmation.
  MariaDB 10.11 requires RHEL 8.10 repositories, so verify the image/repository
  combination before the full deployment.
- Application flavor: no suitable pre-existing flavor. The bootstrap creates a
  private `techsprint.2c4r` flavor and grants each developer project access.
- Placement: six 4096-MB guests are schedulable across `compute0` and
  `compute1`; the 8:1 ratio is suitable for a functional lab demo, not load
  testing.
- External network: `provider-datacentre`.
- Storage network: `provider-storage`, used by native CephFS clients.
- Object storage: Swift is live; each environment gets a dedicated
  `svc-...-swift` identity with only `swiftoperator` in that project. Its
  mode-`0600` credential is owned by the Apache account running rclone.
- File storage: Manila is live on `hostgroup@cephfs#cephfs`. The required private
  share type uses `driver_handles_share_servers=false` and
  `share_backend_name=cephfs`.
- Load balancing: Octavia exposes Amphora and OVN. The implementation selects
  Amphora `SINGLE` because RHOSP 16.1 OVN lacks health monitors.
- Networking: a bounded create/delete probe proved project-specific Neutron
  RBAC and a management-owned port on a developer-owned network.

The probe was completely cleaned up and created no workload resource.

## 1. Authenticate

```bash
source ~/Downloads/proj-xxxx-openrc.sh
openstack token issue -f table -c project_id -c expires
```

| Error | Cause |
|---|---|
| `Could not find versioned identity endpoints` | `OS_AUTH_URL` is missing `:5000/v3` |
| `The request you have made requires authentication` | wrong password, or wrong domain name (case-sensitive) |
| `Unable to establish connection` | you are outside the lab network; connect to the course VPN |
| `SSL: CERTIFICATE_VERIFY_FAILED` | self-signed lab cert; set `OS_CACERT=/path/to/lab-ca.pem` |

## 2. Values you need

```bash
# External network - both the UUID and the name are needed
openstack network list --external -f table

# Cloud-specialized RHEL-family image
openstack image list --status active -f table | grep -iE 'rhel|rocky|centos|stream'

# Flavor with EXACTLY 2 vCPU and 4 GB. Names lie; check the numbers.
openstack flavor list -f table
openstack flavor show default -c name -c vcpus -c ram -c disk

```

Fill in `iac/openstack/terraform.tfvars`:

```hcl
external_network_id   = "7d3c9e1f-...."
external_network_name = "provider-datacentre"
storage_network_id    = "<provider-storage-uuid>"
image_name            = "rhel8"
developer_flavor_name = "techsprint.2c4r"
jump_flavor_name      = "default"
admin_username        = "cloud-user"
admin_source_ip       = "<your.ip>/32"
```

### The login user must match the image

A wrong value here surfaces as `Permission denied (publickey)` on an otherwise
perfect deployment.

| Image family | Default user |
|---|---|
| Rocky Linux | `rocky` or `cloud-user` |
| CentOS Stream | `cloud-user` |
| RHEL | `cloud-user` |
| Ubuntu | `ubuntu` |

If unsure, boot one instance and read the console log:

```bash
openstack console log show <server> | grep -iE "authorized keys|login as|ci-info"
```

On the bounded smoke-test instance, verify the required stream without changing
the cloud:

```bash
cat /etc/redhat-release
dnf module list mariadb:10.11
```

RHEL 8.10 provides the stream. If the Academy image is older and its repositories
do not expose 10.11, stop and select/update a compatible image; using MariaDB
10.5 would violate Moodle 4.5's minimum database version.

### No Rocky or CentOS image in the lab?

The brief requires one of them, so upload it. ~1 GB through the lab network:

```bash
curl -fLO https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2

openstack image create "Rocky-9-GenericCloud" \
  --file Rocky-9-GenericCloud-Base.latest.x86_64.qcow2 \
  --disk-format qcow2 --container-format bare \
  --property os_distro=rocky --property os_version=9 \
  --min-disk 10 --min-ram 2048 \
  --private
```

## 3. Capability checks

The validated design uses all services below and has no fallback switches:

```bash
for service in compute network image block-storage object-store load-balancer sharev2; do
  if openstack catalog list -f value -c Type | grep -qx "$service"; then
    echo "OK      $service"
  else
    echo "MISSING $service"
  fi
done
```

If one is missing, use the confirmed CL110 lab rather than carrying an untested
second architecture in the code.

## 4. Quotas

The brief needs 2 developers × 2 application instances, one jump VM and two
1-GB Amphora `SINGLE` instances. Placement—not the deprecated hypervisor
`free_ram_mb` field—is the authoritative capacity source.

```bash
openstack quota show -f table
openstack limits show --absolute -f table
```

Minimum for the tested configuration:

| Resource | Needed | Why |
|---|---|---|
| Instances | 7 | 4 Moodle + 1 bastion + 2 single Amphorae |
| vCPUs | Check quota | 4 × 2 plus the existing jump and Amphora flavors |
| RAM | Check quota | 16 GB application RAM plus jump and Amphora RAM |
| Volumes | 9 | 4 boot + 4 data + 1 bastion |
| Volume storage | ~200 GB | 20 GB boot × 5 + 32 GB data × 4 |
| Floating IPs | 1 | The bastion only |
| Networks / routers | 3 each | 2 developers + management |
| Security groups | 3+ | one per project |

**If the quota is smaller than that**, reduce in this order and document each
reduction — the first two cost no marks:

1. `data_disk_size_gb = 16` (the brief requires two disks, not large ones)
2. Boot volume 20 GB → 12 GB
3. **Do not** reduce below 2 developers or 2 Moodle instances — both are graded.

## 5. No admin rights? The single-project fallback

This is a manual design alternative, not a mode implemented by `deploy.sh`.
The confirmed CL110 account has the admin rights required by the main design.

Creating Keystone projects and users needs the `admin` role in the domain. Test
it:

```bash
openstack project create --description probe probe-delete-me \
  && openstack project delete probe-delete-me \
  && echo "you can create projects"
```

If you cannot, you lose the tenant-isolation primitive but can keep most of the
marks. Deploy everything into your single project, and substitute:

| Requirement | Full version | Single-project version | Marks at risk |
|---|---|---|---|
| Separate projects/tenants (I3, 1 pt) | project per developer | one project | **1 point lost** — document why |
| Isolated network per developer (I2, 2 pts) | network per project | one network **per developer** in the same project, no router between them | **0** — still satisfied |
| Users from CSV (I3, 3 pts) | Keystone users | cannot create; use application credentials per developer and explain | up to 3 at risk |
| Developers control only their own (I3, 2 pts) | role per project | security groups + separate networks; document the policy limitation | partial |
| Everything else | unchanged | unchanged | 0 |

Concretely: keep one Neutron network **per developer** inside your single
project, with no router path between them, and rely on security groups scoped by
`remote_group_id`. The network isolation requirement is still met; only the
tenant-separation point is not.

Write this up as a constraint of the lab environment rather than omitting it. An
assessor who knows the academy labs will recognise the situation, and a
documented workaround scores far better than a silent gap.

## 6. Everything at once

```bash
make openstack-discover
```

Prints the domain, external/storage networks, images, flavors, required service
catalog entries and quotas. Save the output—the report's environment section is
largely this.

---

Previous: [Azure networking explained](09-azure-network.md) ·
Next: [Known limitations](13-known-limitations.md)

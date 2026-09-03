# Troubleshooting

Symptom-first. Find the error text you are looking at. Lab-specific discovery
for the Red Hat Academy cloud is in the
[second half of this document](#openstack-lab-discovery).

---

## The deployment script

### `fail az is not installed` / `not logged in to Azure`

Preflight working as intended — it stops before creating anything.

```bash
az login && az account set --subscription "<id>"
```

### `fail OS_AUTH_URL is unset`

Source the OpenStack RC file in the same shell that runs `deploy.sh`:

```bash
source ~/Downloads/proj-xxxx-openrc.sh
```

### `CSV validation failed`

The message names the line and the problem. Nothing was created.

```
CSV validation failed:
  line 3: role 'devloper' is not one of ['developer', 'devops_lead']
```

### `these users collapse to the same resource name`

Two people slugify identically — `luka lukic` and `luka lazic` both give
`lukal`. Storage account names must be unique, so the parser refuses. Change one
row, for example to a fuller surname.

### Ansible fails but Terraform succeeded

The infrastructure exists. Re-run only the configuration half:

```bash
ansible-playbook -i ansible/inventory/azure.yml ansible/site.yml
```

Add `-vvv` for the SSH transcript, or `--limit marion-moodle-1` to iterate on one
host.

---

## Terraform, Azure

### `Subscription is not registered to use namespace`

```bash
for p in Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.ManagedIdentity; do
  az provider register --namespace "$p"
done
```

### `You have not accepted the legal terms` / marketplace purchase error

Rocky Linux is a marketplace image:

```bash
az vm image terms accept --urn resf:rockylinux-x86_64:9-base:latest
```

Or switch to a first-party image, which also requires dropping the plan block:

```hcl
os_image = {
  publisher = "Canonical"
  offer     = "ubuntu-24_04-lts"
  sku       = "server"
  version   = "latest"
}
os_image_requires_plan = false
```

Note that the brief asks for Rocky or CentOS Stream, so prefer accepting the
terms. If you must switch, `ansible/roles/moodle/defaults/main.yml` also needs
Debian-family package names and `apache_service: apache2`.

### `Authorization_RequestDenied` creating an application

The CSV fallback needs permission to register applications; it does not require
User Administrator.

```bash
az rest --method get \
  --url 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' \
  --query "defaultUserRolePermissions.allowedToCreateApps" -o tsv
```

The value must be true. Otherwise the tenant administrator must create the
identities, or the lecturer must approve a different demonstrable identity
mechanism.

### `AuthorizationFailed` creating the custom role definition

Creating role definitions needs **Owner** or **User Access Administrator** on
the subscription.

```bash
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --include-inherited --query "[].roleDefinitionName" -o tsv
```

Fallback that keeps most of the marks: assign the built-in
`Virtual Machine Contributor` at resource-group scope instead, and document that
the least-privilege intent could not be expressed because of tenant policy.
Explain what the custom role *would* have contained — the reasoning is what the
2 points are for.

### `SkuNotAvailable` for Standard_B2s

```bash
az vm list-skus --size Standard_B2s --all \
  --query "[?resourceType=='virtualMachines' && length(restrictions)==0].locationInfo[0].location" \
  -o tsv | sort -u | head
```

Change `location`, or use `Standard_B2as_v2` / `Standard_D2s_v3` — all satisfy
2 vCPU / 4 GB.

### `StorageAccountAlreadyTaken`

Storage account names are globally unique. The module appends a random 4-digit
suffix and always preserves it after truncating the descriptive base. In the
unlikely event of a collision, explicitly replace only that random resource:

```bash
terraform -chdir=iac/azure apply -replace='module.developer_env["marion"].random_string.storage_suffix'
```

### `The request may be blocked by network rules of storage account`

`default_action = "Deny"` locked out your own workstation. `admin_source_ip` must
be your current address:

```bash
curl -s https://ifconfig.me    # compare with terraform.tfvars
```

Home connections rotate addresses. Update `admin_source_ip` and re-apply.

### Quota exceeded / `Operation could not be completed as it results in exceeding quota`

Azure for Students has low regional vCPU quotas — often 4 to 10 total. Four B2s
VMs is 8 vCPU plus the jump host.

```bash
az vm list-usage --location westeurope \
  --query "[?contains(localName,'Total Regional') || contains(localName,'Standard B')].{name:localName,current:currentValue,limit:limit}" \
  -o table
```

Student subscriptions usually cannot raise quotas. Deploy one cloud at a time, or
temporarily reduce to `moodle_instance_count = 2` with a single developer to
validate, then scale up. Do **not** submit with fewer than 2 developers or 2
instances — both are graded.

---

## Terraform, OpenStack

### `Could not find versioned identity endpoints`

`OS_AUTH_URL` needs the `:5000/v3` suffix.

### `You are not authorized to perform the requested action: identity:create_project`

You lack the `admin` role in the domain. Use the single-project fallback in
[section 5 below](#5-no-admin-rights-the-single-project-fallback).

### `No valid host was found`

Almost never a full cluster. In order of likelihood:

```bash
openstack quota show -f table                              # 1. quota exhausted
openstack flavor show <flavor> -c vcpus -c ram -c disk      # 2. flavor disk < image min_disk
openstack image show <image> -c min_disk -c min_ram
openstack availability zone list                           # 3. AZ does not exist
openstack server show <server> -f value -c fault           # 4. the actual reason
```

### `Invalid input for external_gateway_info`

`external_network_id` is wrong, or is a name rather than a UUID:

```bash
openstack network list --external -f value -c ID -c Name
```

### Instance is ACTIVE but Ansible cannot reach it

```bash
# 1. Did cloud-init run?
openstack console log show vm-techsprint-test-marion-moodle-1 | tail -40
# look for TECHSPRINT-NODE-1-READY

# 2. Right login user for this image?
openstack console log show <server> | grep -i "authorized keys"

# 3. Does the security group allow this network's jump port at .253?
openstack security group rule list sg-techsprint-test-marion-moodle -f table

# 4. Is the bastion's floating IP still attached?
openstack floating ip list -f table
```

`cloud-init status --wait` returns `2` for a recoverable degraded status; the
deployment accepts 0 or 2 but fails immediately on a hard error. On the
multihomed jump host also inspect:

```bash
systemctl status techsprint-jump-routes.service
journalctl -u techsprint-jump-routes.service
```

The route service retries when interfaces are not ready yet.

### Manila share exists but has no export location

Manila publishes `export_locations` asynchronously. Terraform and Ansible now
fail closed rather than treating an empty path as an optional mount. Inspect:

```bash
openstack share show <share-id> -f yaml
openstack share export location list <share-id>
```

Wait for the share to become `available`, then rerun the same deployment. A live
CL110 apply is still required to establish whether the provider waits long
enough before reading the export.

### Octavia load balancer stuck in `PENDING_CREATE`

The discovered lab has a working Amphora provider and `octavia_65` flavor.
Inspect the load balancer, amphora and Octavia status instead of silently
substituting a different architecture:

```bash
openstack loadbalancer show <lb-id> -f yaml
openstack loadbalancer amphora list -f table
openstack loadbalancer status show <lb-id>
```

If the bounded runtime smoke cannot create a healthy Amphora, stop and preserve
the API errors; do not continue to the graded full deployment.

---

## Ansible

### `Failed to connect to the host via ssh` on every Moodle node

The ProxyCommand is the whole access path. Test it manually:

```bash
ssh -i build/ssh/id_ed25519 techsprint@<bastion> true            # bastion reachable?
ssh -i build/ssh/id_ed25519 \
  -o ProxyCommand="ssh -W %h:%p -i build/ssh/id_ed25519 techsprint@<bastion>" \
  techsprint@10.10.1.4 true                                       # through it?
```

If the bastion works and the node does not, check the app NSG's
`allow-ssh-http-from-hub` rule and both directions of the hub/spoke peering.

### `No candidate data disk found`

The data disk is not attached, or already has a partition table.

```bash
ssh marion-moodle-1 'lsblk'
az vm show -g rg-techsprint-test-marion -n vm-techsprint-test-marion-moodle-1 \
  --query "storageProfile.dataDisks" -o table
openstack server show vm-... -f value -c volumes_attached
```

Azure waits for `/dev/disk/azure/scsi1/lun10`; OpenStack requires exactly one
non-root disk. The filesystem task never uses `force`, so a re-run preserves
existing data.

### `mount error(13): Permission denied` on the Azure Files share

The storage account key is wrong, SMB is blocked on the network path, or the
share has not finished provisioning.

```bash
ssh marion-moodle-1 \
  "sudo awk -F= '{print \$1\"=<redacted>\"}' /etc/smbcredentials-techsprint"
az storage account show -n <account> -g <rg> --query networkRuleSet -o yaml
```

The subnet needs `service_endpoints = ["Microsoft.Storage"]` **and** to be listed
in the account's `virtual_network_subnet_ids`.

### Moodle installer fails: `Cannot connect to the database`

```bash
ssh marion-moodle-1 'sudo systemctl status mariadb; sudo ss -tlnp | grep 3306'
ssh marion-moodle-2 'timeout 5 bash -c "</dev/tcp/10.10.1.4/3306" && echo reachable'
```

MariaDB binds to the private address, so it must have come up *after* the NIC had
one. If `bind-address` is wrong, restart it. Also confirm the NSG rule allowing
3306 between ASG members exists.

### nginx or Apache returns 502 on Rocky

SELinux blocking the proxy or database connection:

```bash
ssh marion-moodle-1 'sudo ausearch -m avc -ts recent'
ssh marion-moodle-1 'sudo setsebool -P httpd_can_network_connect 1 \
                                    httpd_can_network_connect_db 1'
```

The role sets these; it bites when you configure something by hand afterwards.

### `dnf` lock errors on the first task

Cloud-init is still installing packages. The roles retry three times with a
15-second delay, and `cloud-init status --wait` runs first. If it still races,
the instance is very slow — re-run the playbook.

---

## Verification

### `marion cannot ping andrijam - ISOLATION BROKEN`

The most serious failure possible: a graded requirement is not met.

```bash
# Is there a peering that should not exist?
az network vnet peering list -g rg-techsprint-test-marion \
  --vnet-name vnet-techsprint-test-marion -o table

# Is forwarded traffic enabled anywhere?
az network vnet peering list -g rg-techsprint-test-hub \
  --vnet-name vnet-techsprint-test-hub --query "[].allowForwardedTraffic" -o tsv
# true is expected for controlled NVA egress; isolation comes from the UDR,
# hub/spoke NSGs and the jump host's nftables forward policy

# Do the CIDRs actually differ?
terraform -chdir=iac/azure output environments | grep vnet_cidr
```

The usual cause is overlapping CIDRs from a hand-edited tfvars file bypassing the
parser.

### Moodle installation was interrupted

The playbook writes `/var/lib/techsprint-moodle-installed` only after the CLI
installer exits successfully. It also checks the required tables plus the
version, admin-user and site-course records. On rerun it:

- restores a missing config/marker when the database is complete;
- resets the Moodle database only when successful queries positively identify
  an incomplete first installation;
- never automatically resets a database after the success marker exists;
- leaves a complete installation unchanged.

Only the incomplete Moodle schema is reset; mounted object/file data is not
deleted. A database-query error aborts recovery instead of being interpreted as
permission to reset data.

### Load-balancer check fails

`SourceIP` affinity deliberately pins the jump host to one backend, so repeated
requests from there are not a valid membership test. `verify.sh` checks each
node directly and then loads Moodle through the balancer.

If the pool has fewer than two members, or one node fails its direct health
check:

```bash
az network lb probe show -g rg-techsprint-test-marion \
  --lb-name lb-techsprint-test-marion-moodle -n probe-moodle-http
ssh marion-moodle-2 'curl -i http://127.0.0.1/healthz.php'
```

The health endpoint names each dependency and returns 503 if Moodle config,
database connectivity, the data disk, object storage or file storage is
unavailable. Use its response together with `findmnt` and `mariadb`.

### Destroy refuses because saved inputs are missing

Destroy intentionally never rebuilds `users.auto.tfvars.json` from a current
CSV: a changed user map could orphan `for_each` resources. Preserve the
generated files under `iac/azure/` and `iac/openstack/`.

OpenStack keeps the same file in both of its roots, `iac/openstack/` and
`iac/openstack/data/`, because the data root reads the identical parsed CSV.
`deploy.sh` copies it into the data root automatically, and destroy refuses if
`iac/openstack/data/users.auto.tfvars.json` is missing rather than inventing
new values. The data root is always destroyed before the bootstrap root, since
it reads the bootstrap state and its resources live inside those projects.

---

## Collect diagnostics before asking for help

```bash
{
  echo "=== versions ==="; terraform version; ansible --version | head -1
  echo "=== azure ==="; az account show --query "{name:name,id:id}" -o yaml
  echo "=== openstack ==="; openstack token issue -f value -c project_id
  openstack catalog list -f value -c Type | sort | tr '\n' ' '; echo
  echo "=== parser ==="; python3 lib/parse_users.py users.example.csv --summary
  echo "=== terraform state ==="
  terraform -chdir=iac/azure state list | head -30
  echo "=== the failing command and its full output ==="
  echo "<paste here>"
} > /tmp/techsprint-diagnostics.txt
```

---

# OpenStack lab discovery

Every OpenStack installation differs. The commands below remain the repeatable
discovery procedure, but the target CL110 RHOSP 16.1 lab was inspected on
26 August 2026 and no longer relies on hypothetical service fallbacks.

```bash
make openstack-discover
```

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

Previous: [Cost estimate](cost-estimate.md) ·
Next: [Demo video script](testing-and-evidence.md#demo-video-script)

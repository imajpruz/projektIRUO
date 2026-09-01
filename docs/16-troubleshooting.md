# Troubleshooting

Symptom-first. Find the error text you are looking at.

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
[10-openstack-discovery.md](10-openstack-discovery.md#5-no-admin-rights-the-single-project-fallback).

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

OpenStack also preserves
`iac/openstack/management/deployment.auto.tfvars.json`, allowing the management
VM and floating IP to be destroyed even when per-environment outputs are gone.
If either saved input is missing, restore it from the deployment workspace
before teardown rather than inventing new values.

---

## Collect diagnostics before asking for help

```bash
{
  echo "=== versions ==="; terraform version; ansible --version | head -1
  echo "=== azure ==="; az account show --query "{name:name,id:id}" -o yaml
  echo "=== openstack ==="; openstack token issue -f value -c project_id
  openstack catalog list -f value -c Type | sort | tr '\n' ' '; echo
  echo "=== parser ==="; python3 lib/parse_users.py examples/users.csv --summary
  echo "=== terraform state ==="
  terraform -chdir=iac/azure state list | head -30
  echo "=== the failing command and its full output ==="
  echo "<paste here>"
} > /tmp/techsprint-diagnostics.txt
```

---

Previous: [Cost estimate](15-cost-estimate.md) ·
Next: [Demo video script](17-video-script.md)

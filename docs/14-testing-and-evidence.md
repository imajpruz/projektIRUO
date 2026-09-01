# Testing and evidence

Points are awarded for *demonstrated* requirements. This page is the list of
things to capture, and the order to capture them in — after teardown you cannot
recreate any of it.

---

## Run everything at once

```bash
mkdir -p evidence
./lib/verify.sh --cloud azure     | tee evidence/verify-azure.txt
./lib/verify.sh --cloud openstack | tee evidence/verify-openstack.txt
```

Each check is labelled with the rubric section it satisfies, so the output maps
directly onto the grading sheet:

```
== Access and application ==
  ok    I2/I4   bastion reachable on SSH

-- marion --
  ok    I2/I4   marion: two Moodle instances exist
  ok    I3/I5   marion node 1: 2 vCPU
  ok    I3/I5   marion node 1: at least 3.5 GB RAM
  ok    I2/I4   marion node 1: data disk mounted
  ok    I2/I4   marion node 1: file storage mounted and writable
  ok    I2/I4   marion node 1: object storage mounted and writable
  ok    I2/I4   marion node 1: Moodle health endpoint works
  ok    I2/I4   marion: load balancer serves Moodle

== Network isolation ==
  ok    I2/I4   marion cannot ping andrijam
  ok    I2/I4   marion cannot reach andrijam over SSH
  ok    I2/I4   marion cannot reach andrijam over HTTP
  ... repeated for every ordered developer pair

== Public exposure ==
  ok    I4      exactly one project public IP exists
```

## The negative tests matter most

An allow test proves a rule exists. A **deny** test proves the rule is the thing
doing the work. These carry the isolation and least-privilege marks, and they are
the fastest evidence to produce.

### Developers cannot reach each other (I2/I4, 2 points each side)

```bash
# From the bastion, into developer A's node, aimed at developer B
ssh -i build/ssh/id_ed25519 techsprint@<bastion> \
  "ssh marion-moodle-1 'ping -c 3 -W 3 10.11.1.4; echo exit=\$?'"
# 100% packet loss, exit=1   <- correct
```

Azure will also tell you *which rule* decided, which is stronger evidence than a
timeout:

```bash
az network watcher test-ip-flow -g rg-techsprint-test-marion \
  --vm vm-techsprint-test-marion-moodle-1 --direction Inbound --protocol TCP \
  --local 10.10.1.4:22 --remote 10.11.1.4:33000
# Access: Deny   RuleName: DenyAllInBound
```

On OpenStack, the token refusal is the evidence:

```bash
OS_USERNAME=mario.nikolis OS_PROJECT_NAME=proj-techsprint-test-andrijam \
  openstack server list
# The request you have made requires authentication.
```

### Developers cannot exceed their permissions (I5, 2 points)

```bash
az login --service-principal --username <marion-client-id> \
  --password "$AZURE_CLIENT_SECRET" --tenant <tenant-id>

az vm restart -g rg-techsprint-test-marion -n vm-techsprint-test-marion-moodle-1
# succeeds - allowed action, own resource group

az vm delete -g rg-techsprint-test-marion -n vm-techsprint-test-marion-moodle-1 --yes
# (AuthorizationFailed) ... does not have authorization to perform action
# 'Microsoft.Compute/virtualMachines/delete'          <- correct

az vm restart -g rg-techsprint-test-andrijam -n vm-techsprint-test-andrijam-moodle-1
# (AuthorizationFailed)                                <- correct

az vm list -o table
# only Mario's own VMs appear
```

Screenshot the two failures. They are worth more than any number of successful
commands.

### Storage credentials are genuinely narrow (I2/I4)

- Azure: verify BlobFuse uses `mode: msi`, no Blob key appears on the VM, and
  the separate Files-account key is confined to a root-only `0600` file.
- OpenStack: verify `/etc/rclone-techsprint.conf` is Apache-owned, mode `0600`,
  and uses the dedicated service identity whose only role is project-scoped
  `swiftoperator`.
- Manila: verify each environment has a different CephX username/key and that
  the native CephFS mount can write, read and delete a probe file.

**Timeout means dropped** (a firewall or security group), **connection refused
means reached but nothing listening** (the firewall allowed it). Know the
difference — an assessor may ask, and if a closed port gives `refused` rather
than `timeout` your firewall is not doing what you think.

## Requirement-by-requirement checklist

| # | Requirement | How to show it |
|---|---|---|
| 1 | Moodle deployed | Browser through SOCKS5 on the private LB URL, showing the site front page |
| 2 | **Two** instances, HA | `verify.sh` count check + the failover demo below |
| 3 | Jump host is the only entry | `az network nic list` showing null public IPs; `openstack floating ip list` showing one row |
| 4 | 2 vCPU, 4 GB | `nproc` and `/proc/meminfo` on the guest, not the flavor name |
| 5 | Two disks, both mounted | `lsblk`, `findmnt /mnt/techsprint-data`; object storage separately at `/var/moodledata` |
| 6 | Approved RHEL-family cloud image | `cat /etc/os-release` |
| 7 | Network isolation | the negative tests above |
| 8 | Internet egress works | `curl -I https://packaging.moodle.org` from a Moodle node |
| 9 | Developers control only their own VMs | the RBAC negative tests above |
| 10 | Lead reaches every VM | use the generated names: `ssh marion-moodle-1 uptime`, etc. |
| 11 | Object storage, auto-mounted | `findmnt /var/moodledata`; write/read/delete a probe file; list the container |
| 12 | File storage, auto-mounted | `findmnt /srv/moodle-backups`; fstab entry; write/read/delete probe |
| 13 | Multi-cloud | both verify runs, side by side |
| 14 | Fully automated | the recorded run |
| 15 | Variable user count | add a CSV row, show `0 to change, 0 to destroy` |
| 16 | Tags on everything | `az resource list --tag project=techsprint` |
| 17 | Naming convention | the same table; names are self-describing |

## Two demonstrations worth rehearsing

### Load balancer failover (proves requirement 2)

```bash
# Terminal 1, on the bastion: watch which backend answers
while true; do curl -sI http://10.10.1.250/ | grep -i x-techsprint-node; sleep 2; done

# Terminal 2: break node 1
ssh marion-moodle-1 'sudo systemctl stop httpd'
```

Within two probe intervals (30 s) every response comes from node 2. Restart
Apache and node 1 rejoins. This is *"simulirati visoku dostupnost"* demonstrated
rather than asserted, and it takes 60 seconds on camera.

### Variable user count (proves requirement 15)

The single best argument for the whole design:

```bash
echo 'ivan;ivic;developer' >> examples/users.csv
./deploy.sh --csv examples/users.csv --cloud azure --plan-only
```

```
Plan: <new resources> to add, 0 to change, 0 to destroy.
```

After the OpenStack bootstrap exists, the new slug receives a new project and
workspace while existing workspace addresses remain stable. Azure requires an
additional quota-compatible region/SKU placement before demonstrating a third
developer; its current defaults intentionally cover the required two.

Also show a rejection, because validation is part of the deliverable:

```bash
printf 'ime;prezime;rola\nluka;lukic;devloper\nana;anic;devops_lead\n' > /tmp/bad.csv
./deploy.sh --csv /tmp/bad.csv --cloud azure
# CSV validation failed:
#   line 2: role 'devloper' is not one of ['developer', 'devops_lead']
# Nothing was created.
```

## Screenshots to take, before teardown

| # | Screenshot | Rubric |
|---|---|---|
| 1 | Azure portal: all resource groups with tags visible | I1 tags, I5 hierarchy |
| 2 | `az resource list --tag project=techsprint -o table` | I1 tags + naming |
| 3 | Azure portal: NSG rules on a developer's app subnet | I4 NSG |
| 4 | Azure portal: the custom role definition's JSON | I5 RBAC |
| 5 | `az role assignment list` for one developer | I5 scoping |
| 6 | **`AuthorizationFailed` on another developer's VM** | I5 least privilege |
| 7 | Horizon: Network Topology for one project | I2 diagram |
| 8 | `openstack role assignment list --names` | I3 IAM |
| 9 | **Keystone refusing a cross-project token** | I3 isolation |
| 10 | Moodle front page in a browser via the tunnel | application deployed |
| 11 | Moodle admin page showing the site name per developer | per-developer environments |
| 12 | Load balancer failover: header changing after stopping node 1 | I2/I4 LB |
| 13 | `lsblk` + `findmnt` + `/etc/fstab` on a node | two disks mounted |
| 14 | Both storage mounts + the object container listing | storage requirements |
| 15 | `verify.sh` output, both clouds | everything |
| 16 | Cost analysis blade showing actual spend | I1 cost |
| 17 | `Plan: N to add, 0 to change, 0 to destroy` after adding a user | variable count |

Name them to match the report's figure numbers — `fig-06-authorization-failed.png`
— so you are not matching filenames to captions at 2 a.m.

## Collect it all

```bash
mkdir -p evidence

# Verification
./lib/verify.sh --cloud azure     | tee evidence/verify-azure.txt
./lib/verify.sh --cloud openstack | tee evidence/verify-openstack.txt

# Inventories
az resource list --tag project=techsprint \
  --query "[].{name:name,type:type,rg:resourceGroup,env:tags.environment,owner:tags.owner}" \
  -o table | tee evidence/azure-resources.txt

# IAM
az role assignment list --all \
  --query "[?contains(scope,'techsprint')].{who:principalName,role:roleDefinitionName,scope:scope}" \
  -o table | tee evidence/azure-rbac.txt
openstack role assignment list --names -f table | tee evidence/openstack-iam.txt

# Terraform's own summaries
terraform -chdir=iac/azure     output identity_summary   | tee evidence/azure-identity.txt
terraform -chdir=iac/openstack output identity_summary   | tee evidence/openstack-identity.txt

# Cost
az consumption usage list \
  --start-date "$(date -u -d '30 days ago' +%Y-%m-%d)" \
  --end-date   "$(date -u +%Y-%m-%d)" \
  --query "[?tags.project=='techsprint'].{resource:instanceName,meter:meterDetails.meterName,cost:pretaxCost}" \
  -o table | tee evidence/azure-costs.txt
```

`evidence/` is gitignored. Attach the files to the document rather than
committing them.

---

Previous: [Known limitations](13-known-limitations.md) ·
Next: [Cost estimate](15-cost-estimate.md)

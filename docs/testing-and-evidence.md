# Testing, evidence and the demo video

Points are awarded for *demonstrated* requirements. The first half of this
document is the list of things to capture, and the order to capture them in —
after teardown you cannot recreate any of it. The second half is the
[demo video script](#demo-video-script).

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
echo 'ivan;ivic;developer' >> users.example.csv
./deploy.sh --csv users.example.csv --cloud azure --plan-only
```

```
Plan: <new resources> to add, 0 to change, 0 to destroy.
```

After the OpenStack bootstrap exists, the new slug receives a new project and
takes the next free provider slot while existing slots remain stable; a fourth
OpenStack developer needs one more provider and module block. Azure requires an
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

# Demo video script

> *"Uz klasičnu dokumentaciju u obliku dokumenta, kako bi ostvarili bodove morate
> snimiti izvršavanje skripte za deployment i objasniti što ona radi. Video
> prenesite na YouTube kao privatni video."*

Two requirements: **record the script running**, and **explain what it does**.
A silent screen recording of a terminal does not meet the second.

Target 12–15 minutes. Upload as **Private** (not Unlisted) and put the link in
the document.

## Before you record

```bash
# 1. Everything is clean
make lint

# 2. Start from nothing, so the run is genuine
./deploy.sh --csv users.example.csv --cloud both --destroy --yes

# 3. Rehearse once, timed. Apply takes 8-15 minutes; you will cut that.
```

Practical setup:

- Terminal font at 16pt or larger. Anything smaller is unreadable after YouTube
  compression.
- Light-on-dark, high contrast.
- **Close anything showing a real password, subscription id or your home IP.**
- `--yes` so you are not waiting on prompts on camera.
- Have `docs/diagrams/` open in a browser tab for the architecture segment.
- Record the long apply, then cut it in editing with a caption saying how long it
  actually took. Do not fake the run.

## Structure

### 0:00–1:30 — What and why

Screen: the architecture diagram.

> "This is the TechSprint project. The task is an automated way to give each
> developer an isolated environment for testing Moodle, on Azure and on
> OpenStack, so the company can compare the two providers.
>
> The requirements that shaped the design: every developer gets their own
> network and cannot reach anyone else's; the only public entry point is a jump
> host; each application VM has two vCPU, four gigabytes and two disks; two
> Moodle instances behind a load balancer for high availability; object storage
> and file storage per developer, both mounted automatically; and the whole
> thing driven from a CSV by a single script.
>
> I'll show the code first, then run it end to end."

### 1:30–3:30 — The CSV and the parser

Screen: `users.example.csv`, then run the parser.

> "The input is the CSV format the brief specifies: first name, surname, role."

```bash
cat users.example.csv
python3 lib/parse_users.py users.example.csv --summary
```

> "The parser does four jobs. It validates — unknown roles, a missing lead, no
> developers are all rejected before anything is created. It slugifies names,
> folding Croatian diacritics to ASCII, because Azure resource names reject them:
> watch what happens with Đurđa Šarić."

```bash
printf 'ime;prezime;rola\nĐurđa;Šarić;developer\nIvan;Ivić;developer\nAna;Anić;devops_lead\n' > /tmp/dia.csv
python3 lib/parse_users.py /tmp/dia.csv --summary
```

> "It detects collisions — two people who would produce the same resource name
> are rejected rather than failing halfway through a deployment. And it assigns
> each developer a disjoint slash-sixteen, so overlapping address space is
> impossible by construction, not by review. Overlap is the cheapest way to
> break the isolation requirement.
>
> The output is a map keyed by slug, not a list, and that matters: Terraform's
> for_each over a map keys state by the slug. For the scaling demo I append the
> new CSV row, preserving both those addresses and the existing placement slots."

### 3:30–6:00 — The infrastructure code

Screen: `iac/azure/main.tf`, then the developer module, then the custom role.

> "Azure is hub and spoke. The hub holds the jump host and the only public IP.
> Each developer gets a resource group, a VNet peered to the hub — and to
> nothing else."

Show the peering block, and point at `allow_forwarded_traffic = true`.

> "Forwarding is enabled only because the jump VM also provides controlled
> outbound NAT. Cross-spoke traffic is still denied by the route design, both
> spoke NSGs, the hub NSG and the jump host's nftables forward policy."

Show the custom role definition.

> "This is the permission model. The brief says developers may start, stop and
> restart only their own VMs. The built-in Virtual Machine Contributor role is
> far too wide — it can delete VMs and resize them. So this is a custom role with
> the required power actions plus read-only portal visibility and no data
> actions, assigned at the developer's own resource group. The lead gets the
> same role on each TechSprint group, without access to unrelated subscription
> resources."

Then briefly: `iac/openstack/main.tf`.

> "OpenStack does the same thing with a different primitive: a Keystone project
> per developer. That is actually a stronger boundary — a user with no role in a
> project cannot even get a token for it. The trade-off is that OpenStack has no
> equivalent of that narrow custom role without changing Nova's policy on the
> controllers, which a tenant on the academy lab cannot do. I cover that
> asymmetry in the document."

### 6:00–7:00 — The one script

Screen: `deploy.sh --help`, then the pipeline diagram.

> "The brief requires one script, run once. This is it. It parses the CSV,
> applies Terraform, generates the Ansible inventory from the Terraform outputs,
> runs Ansible, and verifies. Nothing between those stages is typed by hand —
> which is the point, because the Moodle nodes have no public address, so the
> inventory has to carry the ProxyCommand through the bastion."

### 7:00–11:00 — Run it

```bash
./deploy.sh --csv users.example.csv --cloud both --yes
```

Narrate over each step, cutting the long apply:

> "Preflight first — tooling and credentials checked before anything is created.
> Then the CSV.
>
> Azure prints its exact resource count and applies the reviewed plan. OpenStack
> then applies a system-scoped identity bootstrap, followed by one data root
> that fills every project and creates the jump host. State the actual final
> counts shown on screen; the historical 118-resource Azure plan predates the
> split Blob/Files accounts.
>
> [cut] That took eleven minutes.
>
> Now the inventory is generated from the outputs — this is where the bastion
> ProxyCommand comes from — and Ansible takes over: Azure uses LUN 10 while
> OpenStack requires one non-root data disk; it is mounted by UUID with nofail,
> both storage services are mounted,
> and Moodle is installed. Node one runs the installer because it writes the
> database schema; node two pulls the resulting config.php, so both nodes serve
> the same site rather than two unrelated ones.
>
> Then verification."

### 11:00–13:00 — Prove it works

**Moodle in a browser:**

```bash
ssh -D 1080 -i build/ssh/id_ed25519 techsprint@<bastion>
```

> "No Moodle VM has a public address, so I reach it through a tunnel via the
> bastion. My browser uses the local SOCKS5 proxy and opens the private load
> balancer address, which is also Moodle's canonical URL. There is Moodle, and
> the site name shows which developer's environment it is."

**Load balancer failover** — the strongest 60 seconds in the video:

```bash
while true; do curl -sI http://10.10.1.250/ | grep -i x-techsprint-node; sleep 2; done
# other terminal:
ssh marion-moodle-1 'sudo systemctl stop httpd'
```

> "Every response is now coming from node two. The health endpoint returns 503
> when Moodle config, its database or any required mount is unavailable, so a
> listening but unusable node is removed from the pool."

**Isolation:**

```bash
ssh marion-moodle-1 'ping -c 3 -W 3 10.11.1.4'
```

> "Mario's node cannot reach Andrija's. And Azure will tell us which rule decided."

```bash
az network watcher test-ip-flow -g rg-techsprint-test-marion \
  --vm vm-techsprint-test-marion-moodle-1 --direction Inbound --protocol TCP \
  --local 10.10.1.4:22 --remote 10.11.1.4:33000
```

**RBAC:**

```bash
read -s AZURE_CLIENT_SECRET
az login --service-principal --username <marion-client-id> \
  --password "$AZURE_CLIENT_SECRET" --tenant <tenant-id>
unset AZURE_CLIENT_SECRET
az vm restart -g rg-techsprint-test-marion -n vm-techsprint-test-marion-moodle-1   # works
az vm delete  -g rg-techsprint-test-marion -n vm-techsprint-test-marion-moodle-1 --yes  # AuthorizationFailed
az vm restart -g rg-techsprint-test-andrijam -n vm-techsprint-test-andrijam-moodle-1      # AuthorizationFailed
```

> "Mario can restart his own VM, cannot delete it, and cannot touch Andrija's. An
> allow test proves a rule exists; a deny test proves the rule is doing the
> work."

### 13:00–14:30 — Variable user count

The strongest argument for the design:

```bash
echo 'ivan;ivic;developer' >> users.example.csv
./deploy.sh --csv users.example.csv --cloud azure --plan-only
```

> "The appended slug creates a new Keystone project and takes the next free
> provider slot while existing slots remain unchanged. The Azure student
> subscription requires a separately discovered region/SKU placement before a
> third developer can be claimed there."

### 14:30–15:00 — Close

> "Both clouds run from the same CSV. The document covers the cost estimate —
> calculated from the exact deployed regions, SKUs and current Azure meters —
> so I build, demo and destroy in one controlled session. It also covers the
> provider comparison and the limitations:
> the database is a single point of failure, sessions use source-IP affinity
> rather than a shared store, and traffic inside the VNet is HTTP. Each of those
> has a documented fix and a price.
>
> Thanks for watching."

## Upload

1. YouTube → Upload → set visibility to **Private**.
2. Title: `TechSprint - Implementacija računarstva u oblaku - <your name>`.
3. Description: repository link, the four diagram references, and a timestamped
   chapter list — chapters make it far easier to mark.
4. Put the link in the Word document **and** check it opens in a private window
   while signed in as the account you shared it with.

> Private on YouTube means only accounts you explicitly share with can view.
> Obtain the assessor's address and verify access while signed in as that
> account; the assignment explicitly requires Private visibility.

## Checklist

- [ ] Script runs start to finish, and the run is real
- [ ] You explain *why*, not just narrate *what*
- [ ] Moodle shown in a browser
- [ ] Load balancer failover demonstrated
- [ ] Isolation negative test shown
- [ ] RBAC `AuthorizationFailed` shown
- [ ] Adding a user shows `0 to change, 0 to destroy`
- [ ] No password, subscription id or home IP visible on screen
- [ ] Cuts are captioned with the real elapsed time
- [ ] Uploaded, visibility set, link verified from another account

---

Previous: [Known limitations](cloud-comparison.md#known-limitations) ·
Next: [Cost estimate](cost-estimate.md) ·
Back to the [README](../README.md)

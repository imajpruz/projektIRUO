# Rubric traceability

The brief awards 100 points across five sections. Every scored line is listed
here with where it is implemented and what evidence to capture. Work through
this table before you submit: a requirement with no evidence row is a
requirement you will not be paid for.

Legend: **auto** = built by `deploy.sh`, **doc** = you must write it,
**demo** = must appear in the video.

---

## I1 — Elementi računarstva u oblaku i otvoreni kod (20)

| Pts | Requirement | Where | Kind |
|---|---|---|---|
| 7 | Explanation of element choices (load balancer, object/file storage, VM type, disk type) | [05-design-decisions.md](05-design-decisions.md) | doc |
| 3 | Azure monthly cost estimate | [15-cost-estimate.md](15-cost-estimate.md) | doc |
| 4 | Comparison of Azure and OpenStack element offerings | [06-cloud-comparison.md](06-cloud-comparison.md) | doc |
| 4 | Naming convention created, documented and applied | [04-naming-and-tagging.md](04-naming-and-tagging.md); shared `name_prefix`/`env_name` locals in both stacks | auto + doc |
| 2 | All resources tagged `project: techsprint` and `environment: testing` | `local.common_tags` in `iac/azure/main.tf`, `local.common_tags` in `iac/openstack/main.tf` | auto |

Tag evidence, run before the demo:

```bash
# Azure: every resource, and its tags. Anything with an empty Tags column loses the 2 points.
az resource list --tag project=techsprint \
  --query "[].{name:name, type:type, env:tags.environment}" -o table

# Count check: tagged resources vs all resources in the project's groups
az resource list --query "length([?tags.project=='techsprint'])"

# OpenStack
openstack server list --long -f value -c Name -c Properties
openstack network list --tags project=techsprint -f table
```

## I2 — Virtualne mreže, pohrana i sigurnosni koncepti (20)

| Pts | Requirement | Where | Kind |
|---|---|---|---|
| 3 | Diagram of the OpenStack architecture | [diagrams/openstack-architecture.md](diagrams/openstack-architecture.md) | doc |
| 7 | Deployment automation without errors | system bootstrap, per-developer project workspaces and management root, orchestrated by one `deploy.sh` invocation | auto + demo |
| 3 | Load balancer implemented | Amphora `SINGLE` with an HTTP monitor in `modules/rhosp-developer-env` | auto |
| 1 | Two disks created and mounted per instance | boot volume + `openstack_blockstorage_volume_v3.data`; mounted by `ansible/roles/storage` | auto |
| 2 | Instances mount object and file storage, least privilege | dedicated project-only Swift identity + rclone; Manila CephFS + per-environment CephX | auto |
| 1 | Security groups correct, separate for dev and lead roles | one application group per project; one jump-host group in management | auto |
| 2 | Network isolation: only jump host public, own network per dev | one floating IP; developer network RBAC grants only management a port | auto |
| 1 | Adequate explanation of the network settings | [07-openstack-network.md](07-openstack-network.md) | doc |

## I3 — Administracija instanci, korisnika, grupa i profila (20)

| Pts | Requirement | Where | Kind |
|---|---|---|---|
| 3 | Diagram of the IAM structure | [diagrams/openstack-iam.md](diagrams/openstack-iam.md) | doc |
| 7 | IAM deployment automation | dedicated domain, projects, CSV users, per-project groups, and role assignments in `iac/openstack/main.tf` | auto + demo |
| 1 | Instances created with 2 vCPU and 4 GB | `developer_flavor_name`; asserted by `lib/verify.sh` on the running guest | auto |
| 3 | Users created from the CSV, in the right groups with the right roles | parser → SQL-backed domain → developer-specific group/project grants | auto |
| 2 | Developers have power control over only their own resources | `member` role scoped to their own project only | auto |
| 1 | Lead controls all resources and can reach all VMs | leads group holds `member` in every project; generated named-host SSH config on the bastion | auto |
| 1 | Separate projects/tenants for isolation | one `openstack_identity_project_v3` per developer | auto |
| 2 | Infrastructure created for ≥2 developers and 1 lead | input is prepared; award only after the live deployment is captured | auto + demo |

## I4 — Virtualne mreže i pohrana, Microsoft (20)

| Pts | Requirement | Where | Kind |
|---|---|---|---|
| 3 | Diagram of the Azure architecture | [diagrams/azure-architecture.md](diagrams/azure-architecture.md) | doc |
| 7 | Deployment automation without errors | `./deploy.sh --csv ... --cloud azure` | auto + demo |
| 2 | Load balancer implemented **and compared** (LB vs App Gateway) | `azurerm_lb` in the developer module; comparison in [08-azure-loadbalancer.md](08-azure-loadbalancer.md) | auto + doc |
| 1 | Storage accounts: Blob for objects, Files for files | separate Blob and Files accounts per developer with `azurerm_storage_container` + `azurerm_storage_share` | auto |
| 1 | Two managed disks created and mounted per instance | `os_disk` + `azurerm_managed_disk.data`; mounted by `ansible/roles/storage` | auto |
| 2 | Storage mounted via Managed Identity / SAS, least privilege | user-assigned identity, `Storage Blob Data Contributor` on **one container** | auto |
| 1 | NSGs and ASGs correctly created | `azurerm_network_security_group` + `azurerm_application_security_group` | auto |
| 2 | VNet per user, public IP only on the jump host | one VNet per developer; the sole `azurerm_public_ip` is in the hub | auto |
| 1 | Adequate explanation of the Azure network settings | [09-azure-network.md](09-azure-network.md) | doc |

> Azure egress is routed through the jump/NVA, so the public-IP inventory
> contains only the jump host as the rubric requires.

## I5 — Administracija na Microsoft tehnologijama (20)

| Pts | Requirement | Where | Kind |
|---|---|---|---|
| 3 | Diagram of the Azure RBAC model | [diagrams/azure-rbac.md](diagrams/azure-rbac.md) | doc |
| 7 | IAM resource deployment automation | CSV-driven app registrations/service principals, custom role and scoped assignments in `iac/azure/main.tf` | auto + demo |
| 1 | Correct instance sizes (2 vCPU / 4 GB) | `developer_placements` validates exact-capacity B2s/D2ls_v6 SKUs | auto |
| 2 | Custom or built-in roles with minimum necessary rights | `azurerm_role_definition.vm_power_operator` — power/read actions only, no delete or resize | auto |
| 2 | Developers can Start/Deallocate only their own resources | that role, scoped to their own resource group | auto |
| 2 | Lead can manage all VM states and reach them via the bastion | same role on every TechSprint resource group; generated named-host SSH config | auto |
| 1 | Logical resource group hierarchy | `rg-techsprint-test-hub` + one `rg-techsprint-test-<slug>` per developer | auto |
| 2 | Infrastructure created for ≥2 developers and 1 lead | as I3 | auto |

---

## Cross-cutting requirements

| Requirement | Where | Kind |
|---|---|---|
| Application is Moodle | `ansible/roles/moodle` | auto |
| **Two** Moodle instances for HA | `moodle_instance_count = 2`, validated ≥2 | auto |
| Jump host is the only entry point | hub module; no public IP on any app VM | auto |
| 2 vCPU, 4 GB, two disks per app VM | variable validation + `lib/verify.sh` | auto |
| Rocky Linux / CentOS Stream | `os_image` default `resf/rockylinux-x86_64`; `image_name` on OpenStack | auto |
| Developers' VMs cannot talk to each other | non-transitive hub-spoke peering; separate Keystone projects | auto |
| VMs reach the internet for packages | jump/NVA source NAT (Azure); router with SNAT (OpenStack) | auto |
| Developers start/stop/restart only their own VMs | custom RBAC role; project-scoped `member` | auto |
| Central lead VM with SSH to all VMs | bastion + generated `~/.ssh/config` | auto |
| Object storage per developer | Blob container; Swift container | auto |
| File storage per developer | Azure Files; Manila native CephFS | auto |
| Both storages auto-mounted | BlobFuse/rclone systemd mount plus Azure Files/CephFS fstab mount | auto |
| Multi-cloud: OpenStack **and** Azure | `--cloud both` | auto |
| Fully automated with IaC | Terraform + Ansible | auto |
| Architecture diagram for both | [diagrams/](diagrams/) | doc |
| Precise Azure cost estimate | [15-cost-estimate.md](15-cost-estimate.md) | doc |
| Script takes a CSV path, variable user count | `--csv`; `for_each` over the parsed map | auto |
| Tested with 2 developers + 1 lead | required live deployment evidence; `examples/users.csv` is only the input | demo |
| **One** script, run once | `deploy.sh` | auto |
| OpenStack via own deploy or RH Academy | RH Academy; see [10-openstack-discovery.md](10-openstack-discovery.md) | doc |
| Private YouTube video explaining the script | [17-video-script.md](17-video-script.md) | demo |
| Script committed to git regularly | this repository | auto |

## Self-audit before submitting

```bash
# 1. Both stacks are valid
terraform -chdir=iac/azure validate
terraform -chdir=iac/openstack validate
terraform -chdir=iac/openstack/environment validate
terraform -chdir=iac/openstack/management validate

# 2. Ansible is clean
ansible-lint ansible/

# 3. Offline parser, stage, inventory and CLI contracts
make test

# 4. Every check passes on live infrastructure
./lib/verify.sh --cloud azure
./lib/verify.sh --cloud openstack

# 5. No secret was ever committed
git log -p | grep -icE "AccountKey=|BEGIN (RSA|OPENSSH) PRIVATE|OS_PASSWORD=[^ ]" || echo clean
```

- [ ] Every row above has evidence
- [ ] All four diagrams are in the document, numbered and referenced in the text
- [ ] Cost estimate uses figures from your own subscription, not the calculator's
- [ ] Video is uploaded, set to **private**, and the link is in the document
- [ ] Git repository access granted to the assessor
- [ ] Document uses the standard template, spell-checked (points are deducted
      for grammar and formatting)
- [ ] Exam term registered on Infoeduka — without this the grade is not recorded

---

Next: [Prerequisites](02-prerequisites.md)

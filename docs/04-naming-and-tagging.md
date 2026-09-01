# Naming convention and tagging

**Worth 6 points (I1):** 4 for a convention *created, documented and applied*,
and 2 for the two mandated tags. Both are cheap marks and both are lost by
inconsistency, so this page is the "documented" half.

---

## The convention

```
<type>-<project>-<environment>-<scope>[-<index>]
```

| Part | Values | Why |
|---|---|---|
| `type` | `rg`, `vnet`, `snet`, `nsg`, `asg`, `vm`, `pip`, `nic`, `lb`, `nat`, `osdisk`, `datadisk`, `id`, `st`, `role`, `grp`, `proj`, `net`, `subnet`, `router`, `sg`, `vol`, `cont` | Sorts alphabetically by kind, so a portal listing groups itself |
| `project` | `techsprint` | Matches the mandated `project` tag |
| `environment` | `test` (short for `testing`) | Matches the mandated `environment` tag. Abbreviated because Azure name lengths are tight |
| `scope` | `hub`, or a developer slug such as `marion` | Names the owner, so any resource's owner is readable without opening it |
| `index` | `1`, `2` | Only where several identical resources exist |

## Worked examples

| Resource | Name |
|---|---|
| Hub resource group | `rg-techsprint-test-hub` |
| Developer resource group | `rg-techsprint-test-marion` |
| Developer VNet | `vnet-techsprint-test-marion` |
| App subnet | `snet-app` |
| Network security group | `nsg-techsprint-test-marion-app` |
| Application security group | `asg-techsprint-test-marion-moodle` |
| First Moodle VM | `vm-techsprint-test-marion-moodle-1` |
| Its OS disk | `osdisk-techsprint-test-marion-moodle-1` |
| Its data disk | `datadisk-techsprint-test-marion-moodle-1` |
| Internal load balancer | `lb-techsprint-test-marion-moodle` |
| Egress route table | `rt-techsprint-test-marion-egress` |
| Managed identity | `id-techsprint-test-marion-moodle` |
| Custom RBAC role | `role-techsprint-test-vm-power-operator` |
| Keystone project | `proj-techsprint-test-marion` |
| Neutron network | `net-techsprint-test-marion` |
| Security group | `sg-techsprint-test-marion-moodle` |
| Cinder volume | `vol-techsprint-test-marion-moodle-1-data` |
| Swift container | `cont-techsprint-test-marion-moodle-files` |
| **Blob account** | `stbtechsprinttestmar4821` |
| **Files account** | `stftechsprinttestmar4821` |

## The storage account exception

Azure storage account names allow only lowercase alphanumerics, are limited to
3–24 characters, and must be unique across **all of Azure** — not just your
subscription. So the convention is applied and then mechanically sanitised:

```hcl
storage_account_base = lower(
  replace("${var.name_prefix}${var.slug}", "/[^a-z0-9]/", "")
)
blob_storage_account_name = "stb${substr(local.storage_account_base, 0, 17)}${random_string.storage_suffix.result}"
file_storage_account_name = "stf${substr(local.storage_account_base, 0, 17)}${random_string.storage_suffix.result}"
```

The `stb`/`stf` prefix identifies the service. The descriptive base is truncated
to 17 characters before the four-character suffix, preserving uniqueness within
the 24-character limit.

This is also why `lib/parse_users.py` caps slugs at 12 characters and rejects
collisions: the storage account name is the tightest constraint in either cloud,
so it governs the whole naming scheme upstream.

## Where the convention is implemented

Not in a document that drifts — in the code that creates the resources.

| Cloud | Location |
|---|---|
| Azure | `local.name_prefix` in `iac/azure/main.tf`; `local.env_name` in `modules/developer-env/main.tf` |
| OpenStack | bootstrap `local.name_prefix`; project module `local.env_name` in `modules/rhosp-developer-env` |
| Slugs | `slugify()` and the 12-character cap in `lib/parse_users.py` |

Because the prefix is computed once from `project_name` and `environment_short`,
renaming the project is a variable change rather than a search-and-replace.

## The two mandated tags

> *"Svi resursi su tagirani s tagovima project: techsprint i environment:
> testing – 2 boda"*

Exactly those two keys, those two values. Applied to everything, plus provenance
that costs nothing:

```hcl
common_tags = {
  project     = "techsprint"      # mandated
  environment = "testing"         # mandated
  managed_by  = "terraform"
}
```

Per-resource tags merge in the owner, so a resource states who it belongs to:

```hcl
tags = merge(local.common_tags, {
  owner = each.value.username     # mario.nikolis
  role  = each.value.role         # developer
})
```

### OpenStack has no single tag system

Worth a sentence in the report, because the implementation genuinely differs by
resource type:

| Resource type | Mechanism | Form |
|---|---|---|
| Neutron (network, subnet, router, security group) | `tags` | list of strings: `["project=techsprint", "environment=testing"]` |
| Nova instances | `metadata` | map: `{project = "techsprint", ...}` |
| Cinder volumes | `metadata` | map |
| Swift containers | container metadata | `X-Container-Meta-*` headers |
| Keystone projects | `tags` | list of strings |

Neutron tags are a flat list, not key-value, so `key=value` strings are the
convention. That asymmetry against Azure's uniform tag dictionary is a small but
real point for the comparison section.

## Verifying the 2 points

Do this before submitting. An untagged resource is a lost mark, and it is
trivially checkable by the assessor.

```bash
# Every tagged resource
az resource list --tag project=techsprint \
  --query "[].{name:name, type:type, env:tags.environment, owner:tags.owner}" -o table

# The check that matters: is anything in our resource groups NOT tagged?
for rg in $(az group list --query "[?tags.project=='techsprint'].name" -o tsv); do
  az resource list -g "$rg" \
    --query "[?tags.project != 'techsprint'].{rg:resourceGroup, name:name, type:type}" \
    -o table
done
# Empty output = all 2 points.
```

```bash
# Counts should match
echo "tagged:  $(az resource list --query "length([?tags.project=='techsprint'])")"
echo "total:   $(az group list --query "[?tags.project=='techsprint'].name" -o tsv \
                 | xargs -I{} az resource list -g {} --query "length(@)" -o tsv \
                 | paste -sd+ | bc)"
```

```bash
# OpenStack
openstack project list --tags project=techsprint -f table
openstack network list --tags project=techsprint -f table
openstack server list --long -f value -c Name -c Properties
openstack volume list --long -f value -c Name -c Properties
```

Screenshot the Azure table with the `Env` and `Owner` columns populated. It
evidences the naming convention *and* both tag points in one image.

## Why this earns marks beyond compliance

Tags are not decoration. They are what makes the deployment operable:

```bash
# Cost attribution per developer - feeds docs/15-cost-estimate.md
az consumption usage list \
  --start-date "$(date -u -d '30 days ago' +%Y-%m-%d)" \
  --end-date "$(date -u +%Y-%m-%d)" \
  --query "[?tags.owner=='mario.nikolis'].{resource:instanceName, cost:pretaxCost}" -o table

# Find orphans after a partial teardown
az resource list --tag project=techsprint --query "[].id" -o tsv | wc -l

# Deallocate every project VM to stop compute charges
for rg in $(az group list --query "[?tags.project=='techsprint'].name" -o tsv); do
  az vm deallocate --ids $(az vm list -g "$rg" --query "[].id" -o tsv) --no-wait
done
```

On a shared subscription an untagged resource is an orphan nobody dares delete.
Say that in the report — it turns a compliance box into a reasoned choice.

---

Previous: [How the deployment works](03-how-it-works.md) ·
Next: [Design decisions](05-design-decisions.md)

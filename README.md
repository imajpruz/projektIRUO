# TechSprint — Implementacija računarstva u oblaku (IRUO 2025/2026)

Automated provisioning of **isolated per-developer Moodle environments** on
**Microsoft Azure** and **OpenStack**, driven by a single CSV of users.

The intended one-command run builds, for every developer row, a private network
with two Moodle instances behind a load balancer, two disks each, mounted object
and file storage, and a project-scoped identity. Static validation and the
OpenStack control plane have been tested; the first workload smoke test is still
pending and is tracked in [docs/setup-progress.md](docs/setup-progress.md).

```bash
./deploy.sh --csv users.example.csv --cloud both
```

Project brief: *Sveučilište Algebra Bernays, Katedra za sistemsko inženjerstvo i
kibernetičku sigurnost*. Deadline **12 September 2026**.

---

## Start here

| | |
|---|---|
| **Just want to run it?** | [Setup — everything after `az login`](docs/setup.md) |
| **New to the repo?** | [How the deployment works](docs/architecture.md#how-the-deployment-works) |
| **Writing the document?** | [Rubric traceability](docs/rubric-traceability.md) — every scored line mapped to where it is implemented |
| **Recording the video?** | [Demo video script](docs/testing-and-evidence.md#demo-video-script) |
| **Something broke?** | [Troubleshooting](docs/troubleshooting.md) |

## What gets built, per CSV row

```
                      DevOps Lead workstation
                                |
                    SSH 22, from one address only
                                |
        ┌───────────────────────▼────────────────────────┐
        │  HUB / management                              │
        │  the only public IP in the deployment          │
        │  jump host + lead VM                           │
        └───┬──────────────────────────────────┬─────────┘
            │ peering / cross-project role     │
   ┌────────▼─────────┐              ┌─────────▼────────┐
   │ developer: marion │              │ developer: andrijam│
   │ 10.10.0.0/16     │   ✕ no path  │ 10.11.0.0/16     │
   │                  │◄────────────►│                  │
   │ load balancer    │              │ load balancer    │
   │  ├ moodle-1      │              │  ├ moodle-1      │
   │  └ moodle-2      │              │  └ moodle-2      │
   │ 2vCPU/4GB, 2 disks each         │ (identical)      │
   │ object + file storage, mounted  │                  │
   │ egress via jump NVA, no inbound │                  │
   └──────────────────┘              └──────────────────┘
```

Azure isolates with a resource group plus a non-transitive hub-and-spoke
peering. OpenStack uses a SQL-backed TechSprint domain and one Keystone project
per developer. Each private network grants only the management project a narrow
Neutron RBAC share, allowing one central jump VM to hold a port in every network
without routing between them.

## Quick start

```bash
# 1. Tooling and credentials
make check                                  # docs/setup.md#prerequisites

# 2. Lab-specific values for the OpenStack side
make openstack-discover                     # prints what to put in terraform.tfvars

# 3. See the plan without creating anything
./deploy.sh --csv users.example.csv --cloud azure --plan-only

# 4. Build it
./deploy.sh --csv users.example.csv --cloud both

# 5. Collect the evidence the report needs
./lib/verify.sh --cloud azure | tee evidence/verify-azure.txt

# 6. Tear it down the same day - see the cost note below
./deploy.sh --csv users.example.csv --cloud both --destroy
```

## The CSV is the interface

```csv
ime;prezime;rola
Ivan;Majpruz;devops_lead
Mario;Nikolis;developer
Andrija;Maric;developer
```

`lib/parse_users.py` validates it, folds Croatian diacritics to ASCII so names
survive Azure resource naming (`Đurđa Šarić` → `durdas`), rejects two people who
would produce the same resource name, and assigns each developer a disjoint
`/16` so address overlap is impossible by construction.

Adding a fourth person is one line:

```bash
echo 'ivan;ivic;developer' >> users.example.csv
./deploy.sh --csv users.example.csv --cloud azure --plan-only
# Expect only additions, with 0 to change and 0 to destroy.
```

**Zero to change, zero to destroy** — the existing developers are untouched.
The demo appends the new row so existing network/region slots stay stable, while
Terraform's `for_each` keys resources by slug rather than a fragile list index.

## Cost warning

The minimum still contains four application VMs, five total VMs, two managed
load balancers, storage, disks, and cross-region peering. It must not be left
running on a student grant. The current-topology worksheet in
[docs/cost-estimate.md](docs/cost-estimate.md) still needs exact regional
prices before it is report-ready. Build, capture evidence, and destroy on the
same day.

## Documentation

Six documents, consolidated so each maps onto a section of the report.

| Guide | Contents | Rubric |
|---|---|---|
| [Setup](docs/setup.md) | Quickstart after `az login`, then the full prerequisites reference | — |
| [Architecture and design decisions](docs/architecture.md) | How the deployment works, design decisions, Azure and OpenStack networking, load balancer comparison, naming and tagging | **I1 13 pts**, I2, I4 |
| [Azure and OpenStack compared](docs/cloud-comparison.md) | Element-by-element comparison, the recommendation, and every known limitation | I1, 4 pts |
| [Rubric traceability](docs/rubric-traceability.md) | Every scored line mapped to its implementation and evidence | all |
| [Testing and evidence](docs/testing-and-evidence.md) | Verification, negative tests, screenshot list, and the demo video script | all |
| [Cost estimate](docs/cost-estimate.md) | Billable topology and the monthly worksheet | I1, 3 pts |
| [Troubleshooting](docs/troubleshooting.md) | Symptom-first fixes, plus the Red Hat Academy lab discovery | — |

### The four required diagrams — 12 points

| Diagram | Rubric |
|---|---|
| [Azure architecture](docs/diagrams/azure-architecture.md) | I4, 3 pts |
| [OpenStack architecture](docs/diagrams/openstack-architecture.md) | I2, 3 pts |
| [Azure RBAC model](docs/diagrams/azure-rbac.md) | I5, 3 pts |
| [OpenStack IAM structure](docs/diagrams/openstack-iam.md) | I3, 3 pts |

Write-up skeleton: [docs/templates/report-outline.md](docs/templates/report-outline.md)

## Repository layout

```
deploy.sh                  The one script the brief requires
users.example.csv          Input format: ime;prezime;rola

lib/
  parse_users.py           CSV -> validated, slugified Terraform input
  deploy_openstack.sh      Internal two-root OpenStack orchestration
  render_inventory.py      Terraform output -> Ansible inventory (with the bastion ProxyCommand)
  verify.sh                Rubric-labelled checks, isolation tests are negative

tests/
  test_helpers.py          Offline parser, stage, inventory and CLI tests

iac/azure/                 Hub-and-spoke, CSV service principals, custom RBAC
  modules/hub/             Bastion: the only public IP
  modules/developer-env/   One isolated environment
iac/openstack/             System-scoped identity and global bootstrap
  data/                    Every tenant resource, one provider alias per project,
                           plus the central jump host and sole floating IP
  modules/rhosp-developer-env/
                           Nova, Cinder, Swift, Manila, and Amphora per project

ansible/
  site.yml                 Storage -> database -> Moodle -> bastion
  roles/common/            RHEL packages and firewalld
  roles/storage/           Data disk by UUID; both storage services mounted
  roles/database/          MariaDB on node 1
  roles/moodle/            PHP, Apache, unattended install, health endpoint
  roles/bastion/           Lead's key and named SSH hosts

docs/                      The guides above
```

## How the requirements are met

| Brief requirement | Implementation |
|---|---|
| Moodle, two instances for HA | `ansible/roles/moodle`, `moodle_instance_count = 2` (validated ≥2) |
| Jump host is the only entry point | one public IP in the hub; no public IP on any app VM |
| 2 vCPU, 4 GB, two disks per VM | quota-compatible B2s/D2ls_v6 + data disk; asserted on the guest by `verify.sh` |
| Cloud Linux | Rocky Linux 9 on Azure; the Academy-provided RHEL 8 cloud image on OpenStack |
| Network isolation between developers | non-transitive peering + default-deny NSGs/NVA; separate Keystone projects |
| Internet egress for packages | jump/NVA source NAT (Azure); router SNAT (OpenStack) |
| Developers control only their own VMs | custom power role at their resource-group scope |
| Lead controls and reaches every VM | scoped power-role assignments plus named SSH hosts on the bastion |
| Object storage per developer | Blob container / Swift container |
| File storage per developer | Azure Files / Manila native CephFS |
| Both auto-mounted | BlobFuse or rclone systemd mount plus fstab-backed Azure Files/CephFS |
| Multi-cloud | `--cloud both` |
| Fully automated with IaC | Terraform + Ansible |
| Variable user count from a CSV | `--csv`; `for_each` over the parsed map |
| One script, run once | `deploy.sh` |

On Azure, BlobFuse uses a managed identity scoped to one private container; no
account key appears in its configuration. Azure Files uses a separate
file-only account whose key is kept in a root-only credential file, so that SMB
credential cannot bypass the Blob managed-identity boundary.

## Development

```bash
make fmt             # rewrite Terraform files
make lint            # fmt-check, validate, tests, ansible-lint, shellcheck, python
make test            # parser, stage bridge, inventory and CLI contracts
make openstack-discover
```

`make lint` currently passes ansible-lint's **production** profile, Terraform
validation on both stacks, and shellcheck at warning level.

## What this does not do

Honest list, expanded in
[docs/cloud-comparison.md](docs/cloud-comparison.md#known-limitations):
the database is a single point of failure (a managed instance is ~25 EUR/month
per developer), sessions use source-IP affinity rather than a shared store,
traffic inside the VNet is HTTP, and the Azure Files mount does need the storage
account key in this implementation. Azure Files managed-identity SMB is a
possible future hardening step, but adds client-side Kerberos tooling. Each
trade-off is documented with a fix.

## Safety

`build/`, `*.tfstate`, `terraform.tfvars`, SSH keys, generated
inventories and `evidence/` are all gitignored. The generated inventory and
Terraform output files are written mode `0600` because they contain the storage
key and the database password. Every destructive path lists what it will delete
and asks first, unless `--yes` is passed.

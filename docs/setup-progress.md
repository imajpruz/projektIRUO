# Setup progress

This file records important setup and validation steps without storing secrets,
account IDs, tenant IDs, tokens, or generated credentials.

## 2026-08-24

### Safety agreement

- Do not commit, push, or delete anything without Ivan's explicit permission.
- Ask before running commands that create, change, or destroy cloud resources.
- Start with read-only checks and review a Terraform plan before deployment.

### Completed

- Azure CLI login completed successfully.
- Confirmed the active subscription is **Azure for Students**.
- Queried the active account, subscription, and tenant read-only; identifiers
  were deliberately not copied into this tracked log.
- The subscription offer-code query returned no value. The subscription name is
  currently the evidence that the student subscription is selected.
- Installed GitHub CLI 2.98.0 and authenticated it through GitHub's browser flow.
- Inspected `https://github.com/imajpruz/iruo`: it is public and empty.
- Initialized this folder as a local Git repository on branch `main`.
- Added `https://github.com/imajpruz/iruo.git` as the `origin` remote.
- Reviewed the official assignment PDF. It is the source of truth; repository
  content is implementation guidance rather than a specification to copy.
- Registered the required Azure Compute, Network, Storage, and Managed Identity
  resource providers after explicit approval. No billable resources were
  created.
- Confirmed the student subscription permits only selected regions and has six
  regional vCPUs. The Azure design must therefore spread the minimum topology
  across permitted regions.
- Confirmed Ubuntu 24.04 under WSL2 is available.
- Installed WSL packages for Python virtual environments, `pip`, `make`, `jq`,
  ShellCheck, `unzip`, and certificate handling.
- Installed checksum-verified Terraform 1.9.8 at `/usr/local/bin/terraform`.
  Terraform 1.15.9 is currently available, but 1.9.8 was selected as the
  repository's documented baseline.
- Created the Python environment `~/.venvs/techsprint`.
- Installed Ansible Core 2.21.3, ansible-lint 26.8.0, OpenStack CLI 10.2.1,
  and the `ansible.posix`, `community.general`, and `ansible.mysql`
  collections (plus `community.mysql`, installed before its module move was
  identified).
- Verified that the existing Windows Azure CLI bridge works from WSL, so a
  second Azure CLI installation is not currently necessary.
- Added the root `init.md` handoff file so another CLI/agent can resume with the
  official source, safety rules, current state, and next steps.
- Created `/home/ivan/techsprint` as the active WSL-native working copy while
  preserving the original Windows folder.
- Normalized WSL file permissions and kept `deploy.sh` and `lib/verify.sh`
  executable.
- Adapted the Azure guidance to the student subscription: Denmark/Austria
  placement, jump-host egress NVA, one public IP, and CSV-driven service
  principals instead of unavailable human-user creation.
- Added a managed-identity BlobFuse2 mount for Moodle data and retained Azure
  Files for backups plus a separately mounted data disk.
- Selected Moodle-compatible PHP 8.2 and MariaDB 10.11 streams and fixed
  one-run configuration ordering.
- Initialized the Azure stack locally with the backend disabled, downloaded
  signed provider plugins, retained the generated provider lock file, and
  passed `terraform validate`.
- Passed Terraform formatting, ShellCheck, CSV parsing, Ansible's production
  lint profile, and Ansible syntax checking.
- Generated the ignored Azure `terraform.tfvars` from the active account and
  current IPv4 with mode `0600`; identifiers were not copied into tracked docs.
- Completed the first Azure plan-only run: **118 to add, 0 to change, 0 to
  destroy**. The plan contains the intended Denmark/Austria VM placements,
  exactly one public IP, no NAT Gateways, and no plan warnings or errors.
- Updated the project CSV to Ivan Majpruz (`ivanm`) as DevOps Lead, Mario
  Nikolis (`marion`) as the Denmark developer, and Andrija Maric (`andrijam`) as
  the Austria developer. The refreshed plan remains 118/0/0.
- Saved the ignored `tfplan` with mode `0600`. Nothing was applied.
- Created local commit `4838ed2` for the validated Azure/Ansible/documentation
  implementation. Nothing was pushed.
- Initialized the OpenStack Terraform stack locally with its backend disabled,
  retained its provider lock file, and passed static validation without using
  OpenStack credentials.

### Current state

- Initial local baseline commit `76937b2` exists on `main`.
- Student-compatible Azure implementation commit `4838ed2` exists on `main`.
- Nothing has been pushed.
- No billable Azure resources have been created.
- The baseline used Ivan's GitHub noreply identity without changing persistent
  Git configuration.
- Rocky Linux Marketplace terms have not been accepted.
- Terraform has been initialized locally with `-backend=false`; it has not been
  applied.
- No Ansible playbook has been run.
- Azure local configuration and a saved plan exist and are gitignored.
- OpenStack `terraform.tfvars` does not exist.

### Next

1. Review the student-compatible Azure implementation and confirm whether the
   lecturer accepts service principals as the tenant-permission fallback.
2. Review the saved Azure plan before considering any deployment.
3. Obtain OpenStack Academy credentials and design that implementation from the
   discovered capabilities.

## 2026-08-26

### RH Academy discovery and bounded probe

- Started the dedicated CL110 RHOSP 16.1 lab and used only the workstation VM.
- Confirmed the service catalog includes Nova, Neutron, Cinder, Swift, Manila,
  Octavia, Keystone, Glance, and Placement.
- Confirmed Placement can schedule at least six 2-vCPU/4096-MB guests across
  `compute0` and `compute1`; the earlier legacy-hypervisor RAM reading ignored
  the configured allocation ratios.
- Confirmed `rhel8` is the available cloud-specialized application image.
- Confirmed Amphora and OVN load-balancer providers. RHOSP 16.1 OVN lacks health
  monitors, so the implementation selects Amphora `SINGLE`.
- Confirmed Manila is live on native CephFS. The accepted share-type settings
  are `driver_handles_share_servers=false` and
  `share_backend_name=cephfs`.
- Ran one explicitly authorized, bounded control-plane probe. It proved:
  - a newly created SQL-backed domain accepts users, groups, projects, group
    memberships, role assignments, and scoped authentication;
  - an exact private 2-vCPU/4096-MB/0-disk flavor can be created;
  - the CephFS Manila share type is accepted;
  - a developer-owned network can grant only the management project
    `access_as_shared`, after which that project can own a port on the network.
- The probe created no VM, volume, share, router, floating IP, Swift container,
  load balancer, or amphora.
- Every probe object was deleted by recorded ID and the post-cleanup inventory
  was clean. The Academy lab was stopped, not deleted.

### Offline implementation changes

- Replaced the invalid single-provider OpenStack design with three staged
  Terraform roots:
  - `iac/openstack/` for system-scoped identity, secrets, application flavor,
    and Octavia flavor;
  - `iac/openstack/environment/` for one project-scoped workspace per
    developer;
  - `iac/openstack/management/` for the central multihomed jump host.
- Added per-developer groups, CSV-created users, a dedicated SQL-backed domain,
  private flavor access, project-scoped Swift service identities, and separate
  database/Moodle administrator passwords.
- Implemented the proven Neutron RBAC model: each developer network grants only
  the management project access, and the central jump receives one
  management-owned port in each network. IP forwarding stays disabled.
- Implemented Swift mounting through rclone and native CephFS mounting through
  CephX credentials.
- Split Azure Blob and Azure Files into separate storage accounts so the
  root-only SMB key cannot bypass Blob managed-identity authorization.
- Narrowed Azure lead RBAC from subscription scope to the hub and developer
  resource groups only.
- Added a subscription-verified Belgium Central placement for the appended
  third-developer scaling demonstration.
- Added an explicit default-drop NVA forward policy and a readiness marker so
  application configuration cannot race outbound connectivity.
- Fixed fresh Moodle installation permissions, generated separate database and
  administrator passwords, disabled BlobFuse caches for the two-node mount, and
  made verification failure terminate the deployment.
- Expanded verification to check the real data/object/file mounts, read/write
  behavior, all ordered isolation pairs, load-balancer membership, scoped Azure
  RBAC, exact public exposure, operating system, and outbound Internet access.
- Static Terraform validation passes for Azure and all three OpenStack roots.
- ShellCheck, Python compilation, and Ansible's production lint profile pass.

### Still not performed

- No Azure or OpenStack workload was deployed.
- No application VM has booted and no Ansible playbook has run against a cloud.
- RHEL `cloud-user`, native CephFS mounting, Swift/rclone behavior, Amphora
  health monitoring, and 4-GB guest stability still require the later bounded
  runtime smoke test.
- The Azure plan must be regenerated because the storage-account split changes
  its resource count; the saved 118-resource plan is now historical only.

### Refreshed Azure plan

- Fixed CRLF normalization in `deploy.sh` for values returned by the Windows
  Azure CLI bridge; `Registered\r` had caused a false provider-preflight
  failure.
- Generated the post-refactor Azure plan: **129 to add, 0 to change, 0 to
  destroy**.
- Audited the machine-readable plan:
  - exactly one public IP, owned by the jump module;
  - no NAT Gateway;
  - four Moodle VMs plus one jump VM;
  - the required Denmark East B2s and Austria East D2ls_v6 placements;
  - four storage accounts, separating Blob and Files for both developers;
  - two internal load balancers and four managed data disks;
  - lead Reader/power assignments only for the hub, Mario and Andrija resource
    groups.
- The refreshed plan produced no warning or error. Nothing was applied.

## 2026-08-27

### Azure simplification

- Compared the Azure stack with `bbernik/iruo-azure-terraform`, a smaller
  student implementation reported as successfully deployed.
- Did not copy four gaps that conflict with this repository's rubric map: extra
  NAT public IPs, Ubuntu application VMs, pre-existing/optional CSV identity
  IDs, and a Blob service that was created but not mounted.
- Simplified the local stack while retaining the scored behavior:
  - one StorageV2 account per developer now contains both the Blob container
    and Files share;
  - removed the two global Entra groups because RBAC assignments are
    per-identity and per-resource-group;
  - removed duplicate Reader assignments and reduced the custom role to VM
    power/read operations;
  - removed the one-member jump ASG, redundant spoke-deny rule, and redundant
    hub outbound rules.
- Kept the jump/NVA path because it is the simplest design that preserves both
  application Internet egress and the literal one-public-IP requirement.
- Kept Rocky Linux, two real shared-site Moodle nodes, both automatic storage
  mounts, CSV-created service principals, and the one-script Terraform/Ansible
  flow.
- The historical 129-resource Azure plan predates this simplification and must
  not be applied. No replacement plan was generated and no cloud resource was
  created or changed.

### Whole-project and OpenStack simplification

- Compared the OpenStack implementation with
  `bbernik/iruo-openstack-terraform`, which demonstrates a much smaller
  passing-grade topology.
- Kept the reference's simple visible model (one network and load balancer per
  developer, one multihomed jump, router SNAT, two app VMs) but did not copy its
  empty-project limitation: Nova and storage resources here still use
  project-scoped tokens.
- The three OpenStack scopes remain internal implementation details. The user
  still runs only `./deploy.sh --cloud openstack`; one root cannot dynamically
  scope a provider for every CSV project.
- Removed the unused alternative OpenStack module, HAProxy/NFS capability
  branches, duplicate Swift service users, extra load-balancer/storage security
  groups, and unused variables/outputs.
- Reused each CSV developer identity for Swift with `swiftoperator` granted
  only in that developer's project.
- Removed ungraded operational extras: the scheduled backup job, fleet helper,
  login banner, deep health endpoint, duplicate mount assertions, and most
  verifier-only hardening checks.
- Standardized the Azure/OpenStack inventory field names and reduced staged
  variable passing to one generated settings object per internal scope.
- Post-simplification validation passes for Azure and all three OpenStack
  Terraform roots, Ansible's production lint profile, ShellCheck, Python
  compilation, CSV rejection cases, the stage bridge, and both inventory
  formats.
- Ivan confirmed that the lecturer approved CSV-generated Azure service
  principals as the fallback for the tenant's human-user creation restriction.
- No Terraform plan/apply/destroy or cloud API mutation was performed.

## 2026-08-28

### Offline reliability pass

- Made plan/destroy behavior safer: conflicting modes are rejected, plan-only
  no longer creates OpenStack workspaces, destroy refuses a different CSV,
  `make clean` preserves destroy inputs, management state cannot be skipped,
  stale inventory is removed, and all saved plans are mode `0600`.
- Typed both OpenStack stage-setting objects, required a valid storage-network
  UUID, centralized the Manila share-type setting, and made a missing share
  export fail immediately.
- Granted project-scoped Swift rights to developers, leads and the staged
  Terraform deployer without recreating separate service users.
- Removed dead Azure module inputs/outputs and bypassed Azure AD replication
  checks for newly created managed/service principals.
- Added deterministic Azure LUN 10 disk selection, OpenStack single-data-disk
  validation, mount readiness checks and a positive-control isolation test.
- Added EPEL/Remi PHP 8.2 with sodium, explicit PHP-FPM startup, application-NIC
  MariaDB binding and a smaller database memory allocation for 4-GB VMs.
- Added `ansible/requirements.yml` and eight committed offline tests covering
  CSV validation, stage data, file permissions, inventory and CLI contracts.
- Replaced obsolete NAT-era cost numbers with a worksheet matching the current
  Denmark/Austria topology.
- `make lint` passes: Azure and all three OpenStack Terraform roots validate,
  all eight unit tests pass, Ansible passes the production profile with zero
  findings, and ShellCheck/Python compilation are clean.
- The final idempotent install succeeded in a fresh draft environment build.
  No cloud credentials were included and no infrastructure plan or mutation ran.

## 2026-08-29

### Verified multi-model review fixes

- Restored separate deny-by-default Azure Blob/Files accounts, subnet storage
  endpoints and jump-host outbound SSH/HTTP restrictions.
- Replaced developer passwords on OpenStack VMs with dedicated Swift-only
  service identities and mode-`0600` Apache-owned rclone configuration.
- Restored dependency-aware load-balancer health checks with HTTP 503 failures,
  and removed world-writable BlobFuse/rclone mount modes.
- Persisted OpenStack management destroy inputs outside `build/`; destroy no
  longer depends on environment outputs and never synthesizes missing user maps
  from a current CSV.
- Restored ICMP, SSH, HTTP and Keystone isolation checks for every ordered
  developer pair; Azure RBAC checks now reject every unexpected assignment.
- Fixed storage probes so cleanup preserves the write/read failure status.
- Restored SELinux management packages and added safe interrupted-install
  recovery. Successful installs are marked; markerless databases are classified
  using final Moodle records, database query errors fail closed, and command
  argv protects generated passwords from shell parsing.
- CI and `make lint` now use `terraform fmt -check -recursive`. Ansible
  collections, python-manilaclient and Azure CLI are pinned.
- Cloud-init recoverable status `2` is accepted, hard errors fail immediately,
  and multihomed route services retry without a start limit.
- RHEL 8.10 officially supports MariaDB 10.11, but the Academy image minor
  version remains a live check. Manila export timing, Azure storage/network
  behavior and all application mounts also remain live-only.
- Offline verification passes: four Terraform roots validate and pass format
  checks, 23 unit tests pass, Ansible passes its production profile with zero
  findings, and ShellCheck/Python compilation are clean.
- No Terraform plan/apply/destroy or command accessing a live cloud was run.

## 2026-09-03

### Documentation consolidated

- Merged the sixteen numbered guides into seven named ones, keeping the original
  wording: `architecture.md` (how it works, design decisions, both networking
  chapters, the load-balancer comparison, naming and tagging),
  `cloud-comparison.md` (comparison plus known limitations), `setup.md`
  (quickstart plus prerequisites), `testing-and-evidence.md` (verification plus
  the video script), `troubleshooting.md` (symptoms plus lab discovery),
  `rubric-traceability.md` and `cost-estimate.md`.
- Moved `examples/users.csv` to `users.example.csv` at the repository root and
  updated every reference in `deploy.sh`, the `Makefile`, `lib/parse_users.py`
  and the documentation.
- The four required diagrams keep their own files under `docs/diagrams/`.

### OpenStack collapsed from three Terraform roots to two

- Added `iac/openstack/data/`, which holds every tenant resource and the
  management jump host. It declares one provider alias per developer slot,
  because Nova, Cinder, Swift and Manila always create in the project their
  token is scoped to, while Neutron and Octavia accept an explicit `tenant_id`.
- Removed `iac/openstack/environment/`, `iac/openstack/management/` and
  `lib/openstack_stages.py`, and rewrote `lib/deploy_openstack.sh` from 396 to
  about 300 lines. The per-developer Terraform workspaces, the per-project token
  exchange, the typed stage files and the output merging are all gone; roughly
  700 lines net were removed.
- `data/` reads the bootstrap state directly and emits one `inventory_data`
  output in the same shape as the Azure root, so each cloud is now a single
  `terraform output -json`. `plan`, state and `--destroy` all still work.
- Split the bootstrap output into non-sensitive `bootstrap_public` and sensitive
  `bootstrap_secrets`, because sensitivity propagates through
  `terraform_remote_state` and would otherwise hide the per-developer summary.
  The unused `bootstrap_data` output was dropped.
- Provider aliases cannot be generated with `for_each`, so OpenStack capacity is
  three developer slots; a fourth needs one more provider and module block, and
  a variable validation fails with that instruction. Slot order is pinned to
  `network_index` so an existing developer never moves alias. The
  variable-user-count requirement is demonstrated on Azure, which has no limit.
- The Manila share type is still created from the driver: it is a cloud-wide
  object whose per-project access list the Terraform provider does not expose.
- Offline verification passes: three Terraform roots validate and pass format
  checks, 29 unit tests pass, Ansible passes its production profile with zero
  findings, and ShellCheck is clean.
- Still live-only: a real `./deploy.sh --cloud openstack`. Offline validation
  cannot exercise the `terraform_remote_state` read or the slot merge, which
  require an applied bootstrap. No cloud command was run.

# TechSprint agent handoff

Last updated: 2026-08-28

Use this file to resume work after an agent/context change. Do not store secrets,
tokens, account IDs, tenant IDs, public IPs, passwords, or generated credentials
here.

## Source of truth

The official assignment is:

`C:\Users\Ivan\Downloads\IRUO_Projekt_2025_2026-2.pdf`

Read it before making design decisions. Files already present in this repository
are implementation guidance and examples, not a specification to copy or deploy
unchanged. Separate mandatory rubric requirements from optional design choices.

The project root is:

`/home/ivan/techsprint`

The original Windows copy remains unchanged at
`C:\Users\Ivan\Documents\techsprint`; do not edit both copies in parallel.

The running setup log is:

`docs/setup-progress.md`

## User rules

- Never commit, push, delete, destroy, or tear down anything without Ivan's
  explicit permission.
- Ask before downloads, installations, clones, pulls, fetches, local/remote
  creation, or cloud configuration changes.
- Never mention Cursor, an AI agent, or generated-by attribution in commits,
  pull requests, tags, or push-related text.
- Do not expose or commit secrets.
- Go step by step and report meaningful progress instead of performing a long
  invisible audit.
- Do not run Terraform apply or destroy without explicit permission.
- Before any cloud deployment, review a saved Terraform plan with Ivan.

Cursor's local approval rules are in:

- `C:\Users\Ivan\.cursor\permissions.json`
- `C:\Users\Ivan\.cursor\cli-config.json`

The CLI config contains personal account metadata and must not be copied into
the repository.

## Official minimum requirements

- Implement both Azure and OpenStack.
- Read a user CSV and support a variable user count through one deployment
  script invocation.
- Test with at least two developers and one DevOps lead.
- Give every developer two Moodle application VMs.
- Every application VM needs 2 vCPU, 4 GB RAM, one OS disk, and one data disk.
- Use Rocky Linux, CentOS Stream, or a cloud-specialized distribution.
- Give every developer an isolated network; developer networks cannot
  communicate.
- Only the jump host may be publicly reachable.
- Application VMs need outbound internet access.
- Developers can control the power state of only their own VMs.
- The lead can control and reach every VM through SSH.
- Give every developer object and file storage and automatically mount both on
  the application VMs.
- Automate infrastructure and configuration with IaC.
- Produce Azure/OpenStack architecture diagrams, IAM/RBAC diagrams, an Azure
  monthly cost estimate, written documentation, a recorded one-run deployment,
  and regular Git history.

## Git state

- Base branch is `main`.
- Remote: `https://github.com/imajpruz/iruo.git`
- Active work is pushed to `cursor/setup-dev-environment-36e8` with an open PR.
- Initial local baseline commit: `76937b2`.
- Student-compatible Azure implementation commit: `4838ed2`.
- The baseline used Ivan's GitHub noreply identity without changing persistent
  Git configuration.
- Windows Git has `core.autocrlf=true`, while Bash files require LF.
  `.gitattributes` enforces LF, and the baseline records `deploy.sh` and
  `lib/verify.sh` as executable.
- Ivan explicitly authorized the current simplification work and branch pushes.

## Azure state

- Azure CLI login is active on an **Azure for Students** subscription.
- The signed-in account is subscription Owner.
- It does not have User Administrator or Global Administrator in the university
  Entra tenant.
- Default users may create application registrations and security groups.
- Do not assume human Entra users are mandatory on Azure: the official Azure
  rubric requires IAM automation and scoped RBAC but does not explicitly repeat
  OpenStack's “users created from CSV” requirement. On 27 August 2026 Ivan
  confirmed that the lecturer approved CSV-generated service principals.
- Required providers were registered with Ivan's approval:
  `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Storage`, and
  `Microsoft.ManagedIdentity`; the preflight also requires
  `Microsoft.Authorization`.
- No billable Azure resources exist.
- Rocky Linux Marketplace terms are not accepted.
- A subscription policy permits only:
  - `germanywestcentral`
  - `denmarkeast`
  - `belgiumcentral`
  - `austriaeast`
  - `switzerlandnorth`
- Each permitted region has six total vCPUs. The official minimum needs nine
  vCPUs if placed in one region, so a single-region design cannot work on this
  student subscription.
- The implemented local multi-region layout is:
  - Ivan Majpruz (`ivanm`): DevOps Lead on the central 1-vCPU jump VM.
  - Mario Nikolis (`marion`): two 2-vCPU/4-GB VMs in Denmark East.
  - Andrija Maric (`andrijam`): two 2-vCPU/4-GB VMs in Austria East.
  - Global VNet peering joins both developer VNets to the central jump VNet.
- Terraform models this placement. The first plan-only run completed
  successfully: 118 add, 0 change, 0 destroy, with one public IP and no NAT
  Gateways. Nothing was deployed.
- Preserve the official “only jump host has a public IP” requirement. A design
  with one NAT Gateway public IP per developer conflicts with the literal
  rubric; consider using the jump host as the controlled outbound NVA/NAT.
- Blob and Files must actually be mounted. Merely writing object-storage
  credentials or a backup script does not satisfy the rubric.

## WSL and toolchain state

- WSL2 Ubuntu 24.04 is installed.
- The active working copy is now `/home/ivan/techsprint` on WSL's Linux
  filesystem. The Windows copy was preserved.
- File permissions were normalized to `0644`, with `deploy.sh` and
  `lib/verify.sh` at `0755`. Generated secrets can now enforce `0600`.
- Do not alternate Terraform execution between Windows and WSL.
- The existing Windows Azure CLI bridge works inside WSL and uses the active
  login. A second Azure CLI installation is not currently needed.
- Installed system tools include Python 3.12, `pip`, `venv`, Git, SSH, curl,
  `make`, `jq`, ShellCheck, and unzip.
- Terraform 1.9.8 is installed at `/usr/local/bin/terraform`. Terraform reports
  1.15.9 as the current release; 1.9.8 was retained as the repository's
  documented baseline.
- Python environment: `~/.venvs/techsprint`
- Activate it with:

  ```bash
  source ~/.venvs/techsprint/bin/activate
  ```

- Installed in the environment:
  - Ansible Core 2.21.3
  - ansible-lint 26.8.0
  - OpenStack CLI 10.2.1
  - `ansible.posix` 2.2.2
  - `community.general` 13.3.0
  - `community.mysql` 5.0.2
  - `ansible.mysql` 5.2.0

## OpenStack state

- RH Academy CL110 RHOSP 16.1 access is available through its workstation VM.
  Keep the Academy environment stopped when it is not actively in use.
- Read-only discovery confirmed Keystone, Nova, Neutron, Cinder, Glance,
  Placement, Swift, Manila and Octavia.
- A bounded create/delete probe proved writable SQL identity domains, exact
  2-vCPU/4096-MB flavor creation, the native-CephFS share type, project-specific
  Neutron RBAC and management-owned cross-project ports. Cleanup was clean.
- Placement can schedule six 4-GB guests across `compute0` and `compute1`. The
  8:1 lab overcommit is suitable for functional testing, not load testing.
- The available cloud image is `rhel8`; the expected `cloud-user` login remains
  to be proven by the runtime smoke test.
- Octavia Amphora and OVN exist. RHOSP 16.1 OVN lacks health monitors, so code
  selects Amphora `SINGLE` using `octavia_65`.
- Manila uses native CephFS, and Swift is mounted through rclone.
- OpenStack Terraform now has a system bootstrap, one project-scoped workspace
  per developer, and a management root for the central multihomed jump.
- All three OpenStack roots pass static validation. No workload was created.

## Actions deliberately not performed

- Terraform was initialized only with `-backend=false` and validation passed.
  A historical Azure plan exists; no apply or destroy was run.
- No Ansible playbook execution.
- No Azure/OpenStack infrastructure deployment.
- No Rocky Marketplace acceptance.
- The WSL handoff recorded gitignored Azure tfvars and a historical plan; this
  Cloud workspace intentionally has neither. Do not print or commit them.
- No generated Terraform state, SSH keys, inventories, or output files.
- Provider lock files exist for Azure and each active OpenStack root.
- The repository is now mirrored on GitHub; current work is on a feature branch.

## Recommended next sequence

1. Review the student-compatible Azure implementation with Ivan.
2. Regenerate and review the Azure plan; the saved 129-resource plan predates
   the 2026-08-27 simplification and is historical only.
3. Transfer the validated repository and lab tfvars to the Academy workstation
   without transferring long-lived personal credentials.
4. With explicit approval, run one bounded workload smoke test for RHEL SSH,
   one 4-GB VM, Swift/rclone, CephFS, router/FIP and Amphora health monitoring.
5. Fix runtime findings offline, then run the full two-developer/one-lead
   deployment, capture evidence and tear it down after separate approval.

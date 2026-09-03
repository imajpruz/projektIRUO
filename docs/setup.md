# Setup: quickstart and prerequisites

The exact order to run things, and the five checks that must pass **before**
Terraform, because each of them otherwise fails halfway through an apply and
leaves half an environment behind.

Total time: about 20 minutes of setup, then 12–18 minutes of unattended apply.

The [second half of this document](#prerequisites) is the detailed tooling and
access reference. Nothing in it creates a billable resource.

---

# Quickstart — everything after `az login`

## Step 1 — Collect the three values you need

You are logged in. Get the three things `terraform.tfvars` wants.

```bash
az account show --output table
```

```bash
# 1. subscription id
az account show --query id -o tsv

# 2. tenant id
az account show --query tenantId -o tsv

# 3. your own public IP - the only source allowed to SSH to the bastion
curl -s https://ifconfig.me
```

Confirm you are on the student offer while you are here:

```bash
az account show --query 'subscriptionPolicies.quotaId' -o tsv
```

Anything mentioning `Student`, `Free` or `Pass` is the grant. If it says
`EnterpriseAgreement`, you are on a shared faculty subscription — ask before
creating anything, because the cost lands on someone's budget and resource-group
names may already be taken.

## Step 2 — The five pre-flight blockers

Run all five now. Each one is a mid-apply failure if you skip it.

### 2.1 Can you create application identities?

The university tenant does not grant student accounts permission to create
human users. The Azure implementation therefore creates one service principal
per CSV row and assigns its role directly at the correct resource-group scope.

```bash
az rest --method get \
  --url 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' \
  --query "defaultUserRolePermissions.allowedToCreateApps" -o tsv
```

The value must be `true`. The lecturer approved this tenant-permission fallback;
disclose that these are non-human operator identities in the report.

### 2.2 Can you create role definitions and assignments?

```bash
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --include-inherited --query "[].roleDefinitionName" -o tsv
```

You need **Owner** or **User Access Administrator** on the subscription. Without
it the custom power-operator role cannot be created; the fallback is in
[troubleshooting.md](troubleshooting.md#authorizationfailed-creating-the-custom-role-definition).

### 2.3 Accept the Rocky Linux marketplace terms

One-time, per subscription. The brief requires Rocky or CentOS Stream.

```bash
az vm image terms accept --urn resf:rockylinux-x86_64:9-base:latest
```

### 2.4 Register the resource providers

New subscriptions have most of these unregistered, and you find out at the worst
moment.

```bash
for p in Microsoft.Compute Microsoft.Network Microsoft.Storage \
         Microsoft.ManagedIdentity Microsoft.Authorization; do
  az provider register --namespace "$p"
done

# Watch until everything says Registered
az provider list --query \
  "[?namespace=='Microsoft.Compute'||namespace=='Microsoft.Network'||namespace=='Microsoft.ManagedIdentity'].{ns:namespace,state:registrationState}" \
  -o table
```

### 2.5 Check the vCPU quota — the most common hard stop

The minimum topology needs nine vCPUs, while this student subscription allows
six per region. The defaults therefore use Denmark East for one developer plus
the jump VM, Austria East for the second developer, and a verified Belgium
Central placement when a third developer is appended for the scaling demo.

```bash
for region in denmarkeast austriaeast; do
  az vm list-usage --location "$region" \
    --query "[?name.value=='cores'].{name:name.localizedValue,used:currentValue,limit:limit}" \
    -o table
done
```

```bash
# Confirm the exact configured sizes have no subscription restrictions.
az vm list-skus --location denmarkeast --size Standard_B2s --all \
  --query "[?name=='Standard_B2s'].{name:name,restrictions:restrictions}" -o json
az vm list-skus --location austriaeast --size Standard_D2ls_v6 --all \
  --query "[?name=='Standard_D2ls_v6'].{name:name,restrictions:restrictions}" -o json
az vm list-skus --location belgiumcentral --size Standard_D2ls_v6 --all \
  --query "[?name=='Standard_D2ls_v6'].{name:name,restrictions:restrictions}" -o json
```

Denmark and Austria must have empty restrictions. Belgium may list only
zone-specific restrictions; because this project does not request a zone,
there must be no location-level restriction.

## Step 3 — Tooling

```bash
git clone <your-repo-url> techsprint && cd techsprint

# Ansible in a virtualenv, so the distro package does not fight pip
python3 -m venv ~/.venvs/techsprint
source ~/.venvs/techsprint/bin/activate
pip install ansible-core ansible-lint python-openstackclient python-manilaclient
ansible-galaxy collection install -r ansible/requirements.yml
```

> Keep that virtualenv **activated** for every step below. `deploy.sh` calls
> `ansible-playbook` from `PATH`, so an inactive venv fails preflight.

Terraform, if you do not have it:

```bash
curl -fsSL https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip -o /tmp/tf.zip
sudo unzip -o /tmp/tf.zip -d /usr/local/bin && terraform version
```

## Step 4 — Fill in the Azure variables

```bash
cd iac/azure
cp terraform.tfvars.example terraform.tfvars
${EDITOR:-nano} terraform.tfvars
cd ../..
```

Three local values:

```hcl
subscription_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
tenant_id       = "11111111-2222-3333-4444-555555555555"
admin_source_ip = "203.0.113.45/32"
```

Everything else defaults to the verified Denmark/Austria placements, two Moodle
instances per developer, Rocky Linux 9, and the mandatory tags.

> `admin_source_ip` must be your **current** address. Home connections rotate;
> if it changes you lose SSH access and Terraform loses storage access.

## Step 5 — Confirm everything is ready

```bash
make check
```

```
== tooling ==
  terraform          /usr/local/bin/terraform
  ansible-playbook   /home/you/.venvs/techsprint/bin/ansible-playbook
  az                 /usr/bin/az
  ...
== credentials ==
  azure              Azure for Students
== configuration ==
  iac/azure          present, 0 placeholder(s) left
```

`0 placeholder(s) left` is the line that matters. Then a free syntax check:

```bash
make lint
```

## Step 6 — Plan, and read it

Creates nothing. This is where a wrong value surfaces cheaply.

```bash
./deploy.sh --csv users.example.csv --cloud azure --plan-only
```

**Check `0 to destroy`.** Anything else means Terraform thinks it is managing
existing resources, and you should find out why before applying.

Skim the plan for the things that are graded: one resource group per developer,
one VNet each, exact 2-vCPU/4-GB sizes, two `azurerm_linux_virtual_machine` per developer,
`azurerm_managed_disk`, `azurerm_storage_container` **and**
`azurerm_storage_share`, the `azurerm_role_definition`, and three
`azuread_service_principal` resources.

## Step 7 — Deploy

```bash
./deploy.sh --csv users.example.csv --cloud azure
```

It prompts once before applying. Add `--yes` to skip the prompt when recording
the video.

For one cloud the script has six top-level steps, taking roughly 12–18 minutes:

| Step | What happens | Roughly |
|---|---|---|
| 1 | Preflight | seconds |
| 2 | CSV parsed, 2 developers + 1 lead | seconds |
| 3 | Terraform applies the saved, reviewed resource plan | 8–14 min |
| 4 | Ansible inventory rendered from the outputs | seconds |
| 5 | Bastion/NVA readiness wait, then Ansible configuration | 5–11 min |
| 6 | Mandatory verification gate | 1–2 min |

If Ansible fails but Terraform succeeded, the infrastructure exists — re-run only
the configuration half rather than starting over:

```bash
ansible-playbook -i ansible/inventory/azure.yml ansible/site.yml
```

## Step 8 — Reach Moodle

No Moodle VM has a public address, so it goes through the bastion. The script
prints the addresses; get them again with:

```bash
terraform -chdir=iac/azure output environments
terraform -chdir=iac/azure output -raw jump_host_public_ip
```

```bash
# Create a SOCKS proxy through the only public entry point
ssh -D 1080 -i build/ssh/id_ed25519 techsprint@<jump-host-public-ip>
```

Configure the browser to use SOCKS5 at `localhost:1080` (proxy DNS through
SOCKS), leave SSH open, and browse to the private load-balancer address printed
by Terraform, such as **<http://10.10.1.250/>**. This matches Moodle's canonical
URL, so redirects and static assets continue through the bastion.

Named SSH access to every host, so you stop copying private addresses:

```bash
terraform -chdir=iac/azure output -raw ssh_config_snippet >> ~/.ssh/config
ssh marion-moodle-1          # proxies through the bastion automatically
```

From the bastion itself, the lead's cross-environment access:

```bash
ssh techsprint@<jump-host-public-ip>
for host in marion-moodle-{1,2} andrijam-moodle-{1,2}; do ssh "$host" uptime; done
```

## Step 9 — Collect the evidence

Do this **before** teardown. None of it can be recreated afterwards.

```bash
mkdir -p evidence
./lib/verify.sh --cloud azure | tee evidence/verify-azure.txt
```

Every check is labelled with the rubric section it satisfies. Then the
screenshots and negative tests in
[testing-and-evidence.md](testing-and-evidence.md) — particularly the two
that carry the most marks:

```bash
# Isolation: developer A cannot reach developer B
ssh marion-moodle-1 'ping -c 3 -W 3 10.11.1.4'      # 100% loss = correct

# RBAC: authenticate as the CSV-generated developer service principal.
read -s AZURE_CLIENT_SECRET
az login --service-principal --username <marion-client-id> \
  --password "$AZURE_CLIENT_SECRET" --tenant <tenant-id>
unset AZURE_CLIENT_SECRET
az vm restart -g rg-techsprint-test-marion  -n vm-techsprint-test-marion-moodle-1   # works
az vm delete  -g rg-techsprint-test-marion  -n vm-techsprint-test-marion-moodle-1 --yes  # AuthorizationFailed
az vm restart -g rg-techsprint-test-andrijam -n vm-techsprint-test-andrijam-moodle-1       # AuthorizationFailed
az logout && az login       # back to your own account
```

Then record the video —
[testing-and-evidence.md](testing-and-evidence.md#demo-video-script) has the
segment-by-segment script.

## Step 10 — Tear it down the same day

The deployment contains four application VMs, two managed load balancers and
persistent disks, so it must not remain running on the student grant. Fill the
current regional prices in [cost-estimate.md](cost-estimate.md) before quoting a
monthly total.

```bash
./deploy.sh --csv users.example.csv --cloud azure --destroy
```

The CSV is checked against the saved deployment input; it is never used to
reconstruct a missing destroy map. Keep `iac/*/users.auto.tfvars.json` until
teardown completes.

```bash
# Confirm nothing survived
az group list -o table
az resource list --tag project=techsprint -o table    # should be empty
```

Check again the next day — usage data lags up to 24 hours:

```bash
az consumption usage list \
  --start-date "$(date -u -d '2 days ago' +%Y-%m-%d)" \
  --end-date   "$(date -u +%Y-%m-%d)" \
  --query "[?tags.project=='techsprint'].{resource:instanceName, cost:pretaxCost}" -o table
```

If you would rather keep it between sessions, deallocate instead — that stops
compute charges but still leaves ~52 EUR/month of disks, IPs and load balancers:

```bash
for rg in $(az group list --query "[?tags.project=='techsprint'].name" -o tsv); do
  az vm deallocate --ids $(az vm list -g "$rg" --query "[].id" -o tsv) --no-wait
done
```

`az vm stop` is the trap: it shuts the guest down but keeps the compute
reservation, so you keep paying. Always `deallocate`.

## The OpenStack half

Same shape, different pre-flight. Do it after Azure works.

```bash
source ~/Downloads/proj-xxxx-openrc.sh
openstack token issue -f table -c project_id -c expires

# Discover the lab-specific values - every one differs per installation
make openstack-discover
```

Copy the lab UUIDs and workstation source address into
`iac/openstack/terraform.tfvars`. The target CL110 lab has already been
validated for Amphora, Swift and native CephFS; the implementation uses those
services directly.

```bash
cd iac/openstack && cp terraform.tfvars.example terraform.tfvars
${EDITOR:-nano} terraform.tfvars && cd ../..

# On fresh state this shows the bootstrap plan only: the data root's providers
# authenticate to projects the bootstrap creates, so its plan becomes available
# after the bootstrap has been applied.
./deploy.sh --csv users.example.csv --cloud openstack --plan-only
./deploy.sh --csv users.example.csv --cloud openstack
./lib/verify.sh --cloud openstack | tee evidence/verify-openstack.txt
```

Details and the no-admin fallback:
[troubleshooting.md](troubleshooting.md#openstack-lab-discovery).

## The whole thing, condensed

```bash
# after az login
az account show --query '{sub:id, tenant:tenantId}' -o yaml
az vm image terms accept --urn resf:rockylinux-x86_64:9-base:latest
az vm list-usage -l denmarkeast --query "[?contains(localName,'Total Regional')].{used:currentValue,limit:limit}" -o table

source ~/.venvs/techsprint/bin/activate
cd iac/azure && cp terraform.tfvars.example terraform.tfvars && $EDITOR terraform.tfvars && cd ../..

make check
./deploy.sh --csv users.example.csv --cloud azure --plan-only
./deploy.sh --csv users.example.csv --cloud azure
./lib/verify.sh --cloud azure | tee evidence/verify-azure.txt
# ...evidence, screenshots, video...
./deploy.sh --csv users.example.csv --cloud azure --destroy
```

---

# Prerequisites

Nothing here creates a billable resource. Get through it once and `deploy.sh`
does the rest.

## Tooling

```bash
# Terraform 1.5+
curl -fsSL https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip -o /tmp/tf.zip
sudo unzip -o /tmp/tf.zip -d /usr/local/bin && terraform version

# Ansible, in a virtualenv so the distro package does not fight pip
python3 -m venv ~/.venvs/techsprint
source ~/.venvs/techsprint/bin/activate
pip install ansible-core ansible-lint
ansible-galaxy collection install -r ansible/requirements.yml

# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash     # Debian/Ubuntu/WSL
sudo apt install --allow-downgrades azure-cli=2.89.1-1~noble
# sudo dnf install -y azure-cli                            # Fedora/RHEL
# brew install azure-cli                                   # macOS

# OpenStack and Manila clients
pip install python-openstackclient python-manilaclient

# Everything else
sudo apt install -y jq shellcheck   # or: sudo dnf install -y jq ShellCheck
```

`deploy.sh` checks all of this in its preflight step and stops with a clear
message rather than failing halfway through an apply.

## Azure access

An **Azure for Students** subscription: <https://azure.microsoft.com/free/students>.
Sign in with the university account — the grant attaches to that identity.

```bash
az login
az account show --query "{name:name, id:id, tenantId:tenantId}" -o yaml
```

### Tenant-compatible Azure identities

The university tenant blocks students from creating human Entra users. The
Azure implementation uses application registrations/service principals for the
CSV identities and assigns their roles directly.

```bash
# Can a default user create applications?
az rest --method get \
  --url 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' \
  --query "defaultUserRolePermissions.allowedToCreateApps" -o tsv
```

The tenant value must be `true`. You also need **Owner** or **User Access
Administrator** on the subscription to create role assignments and custom role
definitions.

```bash
# Subscription-level rights
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --include-inherited --query "[].roleDefinitionName" -o tsv
```

Document the lecturer-approved service-principal fallback. The official Azure
rubric requires automated IAM and scoped RBAC but does not repeat OpenStack's
explicit requirement for human users created from the CSV.

### Accept the Rocky Linux marketplace terms

One-time, per subscription. Without it the VM creation fails with a terms error.

```bash
az vm image terms accept --urn resf:rockylinux-x86_64:9-base:latest
```

Prefer CentOS Stream or a first-party image? Change `os_image` and set
`os_image_requires_plan = false` — first-party images reject a `plan` block.

### Confirm both regional VM placements are available

```bash
az vm list-skus --location denmarkeast --size Standard_B2s --all \
  --query "[?name=='Standard_B2s'].{name:name,restrictions:restrictions}" -o json
az vm list-skus --location austriaeast --size Standard_D2ls_v6 --all \
  --query "[?name=='Standard_D2ls_v6'].{name:name,restrictions:restrictions}" -o json
```

Empty `restrictions` arrays are required. This split keeps each region below
the Azure for Students six-vCPU limit.

## OpenStack access

Credentials come from the Red Hat Academy lab: Horizon → user menu →
*OpenStack RC File*.

```bash
source ~/Downloads/proj-xxxx-openrc.sh
# Please enter your OpenStack Password: ...

openstack token issue -f table -c project_id -c expires
```

The Terraform provider reads the same `OS_*` variables as the CLI, so a sourced
RC file is the entire setup.

### You need admin rights to create projects

Same shape of problem as Entra ID. Creating Keystone projects, users and role
assignments requires the `admin` role in the domain:

```bash
openstack role assignment list --user "$OS_USERNAME" --names -f table
openstack project create --description probe probe-delete-me && \
  openstack project delete probe-delete-me && echo "you can create projects"
```

If you cannot, read
[troubleshooting.md](troubleshooting.md#5-no-admin-rights-the-single-project-fallback)
for the single-project fallback, which keeps most of the marks.

### Discover the lab's specifics

Every OpenStack install differs. Run this and copy the values into
`iac/openstack/terraform.tfvars`:

```bash
make openstack-discover
```

It prints the external/storage networks, cloud image, Placement-relevant
flavors and service catalog. The target CL110 lab uses a Terraform-
created TechSprint domain and application flavor, plus Amphora and native
CephFS.

## SSH keys

You do not generate one. Terraform creates an ED25519 keypair per cloud, writes
the private half to `build/ssh/id_ed25519` with mode 0600, and installs the
public half on every host. `build/` is gitignored.

## Configure the stacks

```bash
cd iac/azure && cp terraform.tfvars.example terraform.tfvars
${EDITOR:-nano} terraform.tfvars
```

```hcl
subscription_id = "<your-subscription-id>"
tenant_id       = "<your-tenant-id>"
admin_source_ip = "<your.ip>/32"     # curl -s https://ifconfig.me
```

```bash
cd ../openstack && cp terraform.tfvars.example terraform.tfvars
# fill in the values printed by `make openstack-discover`
```

## Final check

```bash
make check
```

```
== tooling ==
  terraform   /usr/local/bin/terraform
  ansible-playbook ~/.venvs/techsprint/bin/ansible-playbook
  az          /usr/bin/az
  openstack   ~/.venvs/techsprint/bin/openstack
  python3     /usr/bin/python3
== configuration ==
  iac/azure/terraform.tfvars      present, 0 placeholders left
  iac/openstack/terraform.tfvars  present, 0 placeholders left
```

Run `make lint` separately for Terraform formatting/validation, offline tests
and Ansible/Shell/Python checks.

---

Next: [Rubric traceability](rubric-traceability.md) ·
[Architecture and design decisions](architecture.md) ·
[Troubleshooting](troubleshooting.md)

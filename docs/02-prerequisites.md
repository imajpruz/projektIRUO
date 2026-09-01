# Prerequisites

Nothing here creates a billable resource. Get through it once and `deploy.sh`
does the rest.

---

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

If you cannot, read [10-openstack-discovery.md](10-openstack-discovery.md) for
the single-project fallback, which keeps most of the marks.

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

Previous: [Rubric traceability](01-rubric-traceability.md) ·
Next: [How the deployment works](03-how-it-works.md)

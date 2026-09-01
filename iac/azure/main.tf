// ============================================================================
// TechSprint - Azure side
//
// One `terraform apply` builds, for every row in the CSV:
//   - a developer: their own resource group, their own VNet (no peering to any
//     other developer), two Rocky Linux Moodle VMs behind a load balancer, two
//     managed disks each, a storage account with Blob and Files, and a
//     CSV-created service principal with start/stop rights on nothing else
//   - the lead: one VM in the shared hub, reachable from the internet, with
//     line of sight to every developer VNet and power control over all of them
//
// Driven entirely by build/users.auto.tfvars.json, which lib/parse_users.py
// generates from the CSV. Nothing here is hardcoded per person.
// ============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  # Provider registration is an explicit preflight step. A plan must not
  # silently mutate subscription configuration by auto-registering services.
  resource_provider_registrations = "none"

  features {
    resource_group {
      // Refuse to delete a resource group holding resources Terraform does not
      // manage. On a shared student subscription this is the guardrail between
      // destroying your environment and destroying a classmate's.
      prevent_deletion_if_contains_resources = true
    }
    virtual_machine {
      // Delete the OS disk with the VM. Without it, every destroy leaves
      // orphaned disks quietly costing money for the rest of the semester.
      delete_os_disk_on_deletion = true
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}

// ----------------------------------------------------------------------------
// Naming convention and mandatory tags
//
// The brief grades both: "Kreirana, dokumentirana i primijenjena konvencija
// imenovanja resursa" (4 points) and the two required tags (2 points).
//
//   <type>-<project>-<environment>-<scope>-<index>
//   vm-techsprint-test-marion-moodle-1
//   rg-techsprint-test-marion
//   st techsprint test marion  ->  sttechsprinttestmarion  (no dashes allowed)
//
// Documented in docs/04-naming-and-tagging.md.
// ----------------------------------------------------------------------------
locals {
  project     = var.project_name // "techsprint"
  environment = var.environment  // "testing"
  env_short   = var.environment_short

  // Exactly the two tags the brief mandates, plus the IaC provenance tag.
  common_tags = {
    project     = local.project
    environment = local.environment
    managed_by  = "terraform"
  }

  name_prefix = "${local.project}-${local.env_short}"

  developer_placement = {
    for slug, developer in var.developers :
    slug => var.developer_placements[developer.network_index]
  }
}

// ----------------------------------------------------------------------------
// SSH key
//
// Generated once and reused by every VM, so the lead's single private key
// opens every host. The private half is written locally with 0600 and is
// gitignored; it never enters Terraform's outputs unmarked.
// ----------------------------------------------------------------------------
resource "tls_private_key" "techsprint" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "ssh_private_key" {
  content         = tls_private_key.techsprint.private_key_openssh
  filename        = "${path.root}/../../build/ssh/id_ed25519"
  file_permission = "0600"
}

// ----------------------------------------------------------------------------
// Entra ID: application identities from the CSV
//
// The university tenant does not grant students User Administrator, so creating
// human Entra users is not possible. The official Azure rubric requires
// automated identities and scoped RBAC, but only the OpenStack rubric explicitly
// requires human users. One service principal per CSV row preserves the
// demonstrable login and least-privilege behavior without elevated tenant roles.
// ----------------------------------------------------------------------------
resource "azuread_application_registration" "identity" {
  for_each = merge(var.developers, var.leads)

  display_name = "app-${local.name_prefix}-${each.key}"
}

resource "azuread_service_principal" "identity" {
  for_each = azuread_application_registration.identity

  client_id = each.value.client_id
}

resource "azuread_application_password" "identity" {
  for_each = azuread_application_registration.identity

  application_id = each.value.id
  display_name   = "terraform-demo-credential"
}

// ----------------------------------------------------------------------------
// Custom RBAC role: power state only
//
// The brief is specific: "Programeri moraju moći sami pokrenuti, ugasiti i
// ponovno pokrenuti isključivo svoje VM-ove." The built-in Virtual Machine
// Contributor is far too broad - it can delete VMs, attach disks and change
// sizes. This custom role grants exactly start, restart, deallocate and read.
//
// Graded under I5: "Dodijeljene custom ili ugrađene role s minimalno
// potrebnim pravima (RBAC)".
// ----------------------------------------------------------------------------
resource "azurerm_role_definition" "vm_power_operator" {
  name        = "role-${local.name_prefix}-vm-power-operator"
  scope       = "/subscriptions/${var.subscription_id}"
  description = "Start, restart and deallocate virtual machines. No create, delete or resize."

  permissions {
    actions = [
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachines/instanceView/read",
      "Microsoft.Compute/virtualMachines/start/action",
      "Microsoft.Compute/virtualMachines/restart/action",
      "Microsoft.Compute/virtualMachines/deallocate/action",
      "Microsoft.Resources/subscriptions/resourceGroups/read",
    ]

    not_actions = []

    // No data actions: this role must not read blobs or file shares. Storage
    // access goes through the VM's managed identity, not the human's account.
    data_actions     = []
    not_data_actions = []
  }

  assignable_scopes = ["/subscriptions/${var.subscription_id}"]
}

// ----------------------------------------------------------------------------
// Hub: jump host and the DevOps Lead VM
//
// Only public IP in the whole deployment lives here. Graded under I4:
// "Mrežna izolacija (VNet po korisniku) i javni IP isključivo na Jump hostu".
// ----------------------------------------------------------------------------
module "hub" {
  source = "./modules/hub"

  name_prefix     = local.name_prefix
  location        = var.hub_location
  tags            = local.common_tags
  vnet_cidr       = var.hub_vnet_cidr
  subnet_cidr     = var.hub_subnet_cidr
  admin_username  = var.admin_username
  ssh_public_key  = tls_private_key.techsprint.public_key_openssh
  vm_size         = var.lead_vm_size
  admin_source_ip = var.admin_source_ip

  // Every spoke CIDR, so the hub NSG can admit only forwarded Internet egress
  // before its explicit inbound deny.
  developer_cidrs = { for slug, dev in var.developers : slug => dev.vnet_cidr }
}

// ----------------------------------------------------------------------------
// One isolated environment per developer
//
// for_each over a map keyed by slug keeps Terraform addresses stable. The
// scaling demonstration appends CSV rows so existing network/placement slots
// also remain unchanged.
// ----------------------------------------------------------------------------
module "developer_env" {
  source   = "./modules/developer-env"
  for_each = var.developers

  slug        = each.key
  name_prefix = local.name_prefix
  location    = local.developer_placement[each.key].location
  tags = merge(local.common_tags, {
    owner = each.value.username
    role  = each.value.role
  })

  vnet_cidr       = each.value.vnet_cidr
  subnet_app_cidr = each.value.subnet_app_cidr

  vm_size        = local.developer_placement[each.key].vm_size
  vm_count       = var.moodle_instance_count
  admin_username = var.admin_username
  ssh_public_key = tls_private_key.techsprint.public_key_openssh
  data_disk_size = var.data_disk_size_gb
  os_image       = var.os_image

  // The hub is the only thing allowed to reach these VMs.
  hub_vnet_id    = module.hub.vnet_id
  hub_vnet_name  = module.hub.vnet_name
  hub_rg_name    = module.hub.resource_group_name
  hub_cidr       = var.hub_vnet_cidr
  hub_private_ip = module.hub.jump_private_ip

  admin_source_ip_for_storage = var.admin_source_ip
  os_image_requires_plan      = var.os_image_requires_plan

}

resource "random_password" "moodle_db" {
  for_each = var.developers

  length  = 24
  special = true
  // Moodle's installer and MariaDB's CLI both choke on quotes and backslashes
  // in a password passed on a command line.
  override_special = "!#%&*()-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
}

resource "random_password" "moodle_admin" {
  for_each = var.developers

  length           = 24
  special          = true
  override_special = "!#%&*()-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
}

// ----------------------------------------------------------------------------
// Role assignments
//
// Developer: power operator, scoped to their own resource group only. This is
// the "isključivo svoje VM-ove" requirement, enforced by scope rather than by
// a condition that could be misread.
// ----------------------------------------------------------------------------
resource "azurerm_role_assignment" "developer_power" {
  for_each = var.developers

  scope                            = module.developer_env[each.key].resource_group_id
  role_definition_id               = azurerm_role_definition.vm_power_operator.role_definition_resource_id
  principal_id                     = azuread_service_principal.identity[each.key].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  description                      = "Power control over ${each.value.display_name}'s own environment"
}

locals {
  techsprint_resource_group_scopes = merge(
    { hub = module.hub.resource_group_id },
    { for slug, env in module.developer_env : slug => env.resource_group_id },
  )

  lead_scope_assignments = merge([
    for lead_slug, lead in var.leads : {
      for scope_name, scope_id in local.techsprint_resource_group_scopes :
      "${lead_slug}:${scope_name}" => {
        lead_slug    = lead_slug
        display_name = lead.display_name
        scope_name   = scope_name
        scope_id     = scope_id
      }
    }
  ]...)
}

// Lead: the same power role in every TechSprint resource group, including hub.
// This satisfies fleet-wide control without granting visibility or power
// operations over unrelated resources elsewhere in the subscription.
// "Voditelj ima kontrolu nad svim resursima i pristup svim VM-ovima."
resource "azurerm_role_assignment" "lead_power_all" {
  for_each = local.lead_scope_assignments

  scope                            = each.value.scope_id
  role_definition_id               = azurerm_role_definition.vm_power_operator.role_definition_resource_id
  principal_id                     = azuread_service_principal.identity[each.value.lead_slug].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  description                      = "${each.value.display_name}: power control over TechSprint scope ${each.value.scope_name}"
}

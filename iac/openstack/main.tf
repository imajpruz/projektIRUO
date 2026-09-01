// ============================================================================
// TechSprint - OpenStack identity and global bootstrap
//
// Nova, Cinder, Swift, and Manila create resources in the provider token's
// project and do not all accept a target project. The data plane therefore
// lives in environment/ and management/, which deploy.sh runs with a correctly
// project-scoped token. This root only manages system-scoped identity, global
// flavors, shared SSH material, and per-environment secrets.
// ============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
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

// Reads OS_AUTH_URL, OS_USERNAME, OS_PASSWORD, OS_PROJECT_NAME and the domain
// variables from the environment, exactly like the openstack CLI. So sourcing
// your RC file is all the authentication setup there is.
provider "openstack" {
  system_scope = true
}

locals {
  name_prefix = "${var.project_name}-${var.environment_short}"

  // OpenStack has no tag system as uniform as Azure's, so the two mandated
  // tags are applied three ways depending on the resource type: as `tags` on
  // Neutron objects, as `metadata` on Nova servers, and as properties on
  // containers. docs/04-naming-and-tagging.md explains the mapping.
  common_tags = [
    "project=${var.project_name}",
    "environment=${var.environment}",
    "managed_by=terraform",
  ]
}

// ----------------------------------------------------------------------------
// One generated SSH key for every OpenStack VM
// ----------------------------------------------------------------------------
resource "tls_private_key" "techsprint" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "ssh_private_key" {
  content         = tls_private_key.techsprint.private_key_openssh
  filename        = "${path.root}/../../build/ssh-openstack/id_ed25519"
  file_permission = "0600"
}

// ----------------------------------------------------------------------------
// Keystone: one project per developer, plus a shared management project
//
// This is the isolation primitive. Two developers in different projects cannot
// see, reach or power-cycle each other's instances, because Keystone will not
// issue either of them a token scoped to the other's project.
// ----------------------------------------------------------------------------
data "openstack_identity_auth_scope_v3" "current" {
  name = "current-scope"
}

resource "openstack_identity_project_v3" "domain" {
  name        = var.identity_domain_name
  description = "SQL-backed identity domain for the TechSprint project"
  is_domain   = true
  enabled     = true
  tags        = local.common_tags
}

resource "openstack_identity_project_v3" "developer" {
  for_each = var.developers

  name        = "proj-${local.name_prefix}-${each.key}"
  description = "TechSprint isolated test environment for ${each.value.display_name}"
  domain_id   = openstack_identity_project_v3.domain.id
  enabled     = true
  tags        = local.common_tags
}

// The management project holds the jump host and the lead's VM. Separate from
// every developer project so the bastion is not inside anyone's blast radius.
resource "openstack_identity_project_v3" "management" {
  name        = "proj-${local.name_prefix}-mgmt"
  description = "TechSprint management: jump host and DevOps lead"
  domain_id   = openstack_identity_project_v3.domain.id
  enabled     = true
  tags        = local.common_tags
}

resource "random_password" "user" {
  for_each = merge(var.developers, var.leads)

  length           = 20
  special          = true
  override_special = "!#%&*()-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
}

resource "openstack_identity_user_v3" "developer" {
  for_each = var.developers

  name               = each.value.username
  description        = "TechSprint developer: ${each.value.display_name}"
  domain_id          = openstack_identity_project_v3.domain.id
  password           = random_password.user[each.key].result
  default_project_id = openstack_identity_project_v3.developer[each.key].id
  enabled            = true

  // Verification authenticates these CSV identities non-interactively.
  ignore_change_password_upon_first_use = true
}

resource "openstack_identity_user_v3" "lead" {
  for_each = var.leads

  name               = each.value.username
  description        = "TechSprint DevOps lead: ${each.value.display_name}"
  domain_id          = openstack_identity_project_v3.domain.id
  password           = random_password.user[each.key].result
  default_project_id = openstack_identity_project_v3.management.id
  enabled            = true

  ignore_change_password_upon_first_use = true
}

// A separate group per developer project preserves group-based RBAC without
// granting every developer access to every project.
resource "openstack_identity_group_v3" "developer" {
  for_each = var.developers

  name        = "grp-${local.name_prefix}-${each.key}-developers"
  description = "Operators for ${each.value.display_name}'s project"
  domain_id   = openstack_identity_project_v3.domain.id
}

resource "openstack_identity_group_v3" "leads" {
  name        = "grp-${local.name_prefix}-devops-leads"
  description = "TechSprint DevOps leads"
  domain_id   = openstack_identity_project_v3.domain.id
}

resource "openstack_identity_user_membership_v3" "developer" {
  for_each = var.developers

  user_id  = openstack_identity_user_v3.developer[each.key].id
  group_id = openstack_identity_group_v3.developer[each.key].id
}

resource "openstack_identity_user_membership_v3" "lead" {
  for_each = var.leads

  user_id  = openstack_identity_user_v3.lead[each.key].id
  group_id = openstack_identity_group_v3.leads.id
}

// --- role assignments -------------------------------------------------------
//
// OpenStack's default policy has no equivalent of Azure's custom "power state
// only" role: `member` can create and delete servers as well as start and stop
// them. Narrowing that needs a policy override on the Nova API, which a student
// project on a shared lab cannot install. So the honest implementation is:
// `member` scoped to their own project, and the isolation comes from the
// project boundary rather than from a narrow role.
//
// This asymmetry with Azure is a genuine finding and belongs in the report -
// see docs/06-cloud-comparison.md.

data "openstack_identity_role_v3" "member" {
  name = "member"
}

data "openstack_identity_role_v3" "swiftoperator" {
  name = "swiftoperator"
}

// Each developer: member in their own project, and nowhere else.
resource "openstack_identity_role_assignment_v3" "developer_own_project" {
  for_each = var.developers

  group_id   = openstack_identity_group_v3.developer[each.key].id
  project_id = openstack_identity_project_v3.developer[each.key].id
  role_id    = data.openstack_identity_role_v3.member.id
}

resource "openstack_identity_role_assignment_v3" "developer_swift" {
  for_each = var.developers

  group_id   = openstack_identity_group_v3.developer[each.key].id
  project_id = openstack_identity_project_v3.developer[each.key].id
  role_id    = data.openstack_identity_role_v3.swiftoperator.id
}

// Leads: member in every developer project plus the management project, so
// "voditelj ima kontrolu nad svim resursima" holds. Assigned to the group, so
// a second lead in the CSV needs no new assignments.
resource "openstack_identity_role_assignment_v3" "lead_all_projects" {
  for_each = var.developers

  group_id   = openstack_identity_group_v3.leads.id
  project_id = openstack_identity_project_v3.developer[each.key].id
  role_id    = data.openstack_identity_role_v3.member.id
}

resource "openstack_identity_role_assignment_v3" "lead_swift" {
  for_each = var.developers

  group_id   = openstack_identity_group_v3.leads.id
  project_id = openstack_identity_project_v3.developer[each.key].id
  role_id    = data.openstack_identity_role_v3.swiftoperator.id
}

resource "openstack_identity_role_assignment_v3" "lead_management" {
  group_id   = openstack_identity_group_v3.leads.id
  project_id = openstack_identity_project_v3.management.id
  role_id    = data.openstack_identity_role_v3.member.id
}

// The Academy admin receives a project role so the staged Terraform roots can
// exchange the system-scoped token for a token scoped to each target project.
resource "openstack_identity_role_assignment_v3" "deployer_developer" {
  for_each = var.developers

  user_id    = data.openstack_identity_auth_scope_v3.current.user_id
  project_id = openstack_identity_project_v3.developer[each.key].id
  role_id    = data.openstack_identity_role_v3.member.id
}

resource "openstack_identity_role_assignment_v3" "deployer_swift" {
  for_each = var.developers

  user_id    = data.openstack_identity_auth_scope_v3.current.user_id
  project_id = openstack_identity_project_v3.developer[each.key].id
  role_id    = data.openstack_identity_role_v3.swiftoperator.id
}

resource "openstack_identity_role_assignment_v3" "deployer_management" {
  user_id    = data.openstack_identity_auth_scope_v3.current.user_id
  project_id = openstack_identity_project_v3.management.id
  role_id    = data.openstack_identity_role_v3.member.id
}

resource "random_password" "object_storage" {
  for_each = var.developers

  length      = 40
  special     = false
  min_lower   = 2
  min_upper   = 2
  min_numeric = 2
}

resource "openstack_identity_user_v3" "object_storage" {
  for_each = var.developers

  name                                  = "svc-${local.name_prefix}-${each.key}-swift"
  description                           = "Swift mount identity for ${each.value.display_name}"
  domain_id                             = openstack_identity_project_v3.domain.id
  password                              = random_password.object_storage[each.key].result
  default_project_id                    = openstack_identity_project_v3.developer[each.key].id
  enabled                               = true
  ignore_change_password_upon_first_use = true
}

resource "openstack_identity_role_assignment_v3" "object_storage" {
  for_each = var.developers

  user_id    = openstack_identity_user_v3.object_storage[each.key].id
  project_id = openstack_identity_project_v3.developer[each.key].id
  role_id    = data.openstack_identity_role_v3.swiftoperator.id
}

resource "random_password" "database" {
  for_each = var.developers

  length           = 32
  special          = true
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

resource "openstack_compute_flavor_v2" "moodle" {
  name        = var.developer_flavor_name
  description = "TechSprint Moodle: exactly 2 vCPU and 4096 MB RAM"
  vcpus       = 2
  ram         = 4096
  disk        = 0
  ephemeral   = 0
  swap        = 0
  is_public   = false
}

resource "openstack_compute_flavor_access_v2" "moodle" {
  for_each = var.developers

  tenant_id = openstack_identity_project_v3.developer[each.key].id
  flavor_id = openstack_compute_flavor_v2.moodle.id
}

data "openstack_compute_flavor_v2" "octavia_amphora" {
  name = var.octavia_amphora_flavor_name
}

resource "openstack_lb_flavorprofile_v2" "single_amphora" {
  name          = "fp-${local.name_prefix}-amphora-single"
  provider_name = "amphora"
  flavor_data = jsonencode({
    loadbalancer_topology = "SINGLE"
    compute_flavor        = data.openstack_compute_flavor_v2.octavia_amphora.id
  })
}

resource "openstack_lb_flavor_v2" "single_amphora" {
  name              = "lbf-${local.name_prefix}-amphora-single"
  description       = "One 1-GB Amphora per developer LB; HTTP health monitors supported"
  flavor_profile_id = openstack_lb_flavorprofile_v2.single_amphora.id
  enabled           = true
}

// Tenant data-plane resources are intentionally absent here. See:
//   environment/ - one project-scoped workspace per developer
//   management/  - the central multihomed jump host and its single floating IP

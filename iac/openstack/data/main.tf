// ============================================================================
// TechSprint - OpenStack data plane
//
// One root, one state, one apply. It replaces the previous environment/ and
// management/ roots, the per-developer Terraform workspaces, and the token
// exchange in lib/deploy_openstack.sh.
//
// Why this root exists separately from ../ at all:
//
//   Neutron, Octavia and Keystone resources accept an explicit tenant_id, so
//   an admin token can create them in any project. Nova, Cinder, Swift and
//   Manila cannot: they always create in the project the token is scoped to.
//   So the data plane needs one provider per target project, and a Terraform
//   provider must be configured before the project it authenticates to can be
//   created. Hence: ../ creates the projects, this root fills them.
//
// Provider aliases cannot be generated with for_each, so developer capacity is
// a fixed number of slots. Three are declared below. Adding a fourth developer
// on OpenStack means adding one provider block and one module block; the
// variable-user-count requirement is demonstrated on Azure, which has no such
// limit. Slots beyond the CSV point at the management project so that an
// unused alias still authenticates.
// ============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
  }
}

// Everything the bootstrap root already knows: project ids, generated
// passwords, the flavor names it created and the shared lab settings. Read
// directly from its state, so no intermediate JSON is written or parsed.
data "terraform_remote_state" "bootstrap" {
  backend = "local"

  config = {
    path = "${path.module}/../terraform.tfstate"
  }
}

locals {
  // Split by sensitivity on purpose: bootstrap_public carries ids, names and
  // settings, bootstrap_secrets carries generated credentials. Only the
  // sensitive inventory_data output touches the latter.
  bootstrap = data.terraform_remote_state.bootstrap.outputs.bootstrap_public
  secrets   = data.terraform_remote_state.bootstrap.outputs.bootstrap_secrets
  settings  = local.bootstrap.settings

  name_prefix             = "${var.project_name}-${var.environment_short}"
  management_project_name = "proj-${local.name_prefix}-mgmt"

  // Slot order must be stable across runs or a developer would move to another
  // provider alias and Terraform would recreate their environment. network_index
  // is assigned once by lib/parse_users.py and never reused.
  ordered_slugs = [
    for index in range(length(var.developers)) :
    [for slug, developer in var.developers : slug if developer.network_index == index][0]
  ]

  slot_slugs = [for index in range(3) : try(local.ordered_slugs[index], "")]

  // Provider configuration may only depend on variables, never on a resource
  // or on remote state, so project names are recomputed from the CSV rather
  // than read back from the bootstrap outputs.
  slot_projects = [
    for slug in local.slot_slugs :
    slug == "" ? local.management_project_name : "proj-${local.name_prefix}-${slug}"
  ]

  management_tags = [
    "project=${var.project_name}",
    "environment=${local.settings.environment}",
    "managed_by=terraform",
    "role=jump-host",
  ]

  management_metadata = {
    project     = var.project_name
    environment = local.settings.environment
    managed_by  = "terraform"
    role        = "jump-host"
  }
}

// The default provider is scoped to the management project, because the jump
// host and its network live here. Developer resources use the aliases below.
provider "openstack" {
  tenant_name         = local.management_project_name
  project_domain_name = var.identity_domain_name
  system_scope        = false
}

provider "openstack" {
  alias               = "developer_0"
  tenant_name         = local.slot_projects[0]
  project_domain_name = var.identity_domain_name
  system_scope        = false
}

provider "openstack" {
  alias               = "developer_1"
  tenant_name         = local.slot_projects[1]
  project_domain_name = var.identity_domain_name
  system_scope        = false
}

provider "openstack" {
  alias               = "developer_2"
  tenant_name         = local.slot_projects[2]
  project_domain_name = var.identity_domain_name
  system_scope        = false
}

// ----------------------------------------------------------------------------
// One developer environment per occupied slot
//
// The three blocks are identical apart from the slot index and the provider,
// which is the price of static provider aliases. Everything else stays in the
// module, so there is one place to change a developer environment.
// ----------------------------------------------------------------------------
module "developer_0" {
  source = "../modules/rhosp-developer-env"
  count  = local.slot_slugs[0] == "" ? 0 : 1

  providers = { openstack = openstack.developer_0 }

  slug                  = local.slot_slugs[0]
  display_name          = var.developers[local.slot_slugs[0]].display_name
  name_prefix           = local.name_prefix
  project_id            = local.bootstrap.developer_projects[local.slot_slugs[0]].id
  management_project_id = local.bootstrap.management_project.id

  tags = [
    "project=${var.project_name}",
    "environment=${local.settings.environment}",
    "managed_by=terraform",
    "owner=${var.developers[local.slot_slugs[0]].username}",
  ]
  metadata = {
    project     = var.project_name
    environment = local.settings.environment
    managed_by  = "terraform"
    owner       = var.developers[local.slot_slugs[0]].username
    role        = "moodle-app"
  }

  subnet_cidr         = var.developers[local.slot_slugs[0]].subnet_app_cidr
  dns_nameservers     = local.settings.dns_nameservers
  external_network_id = local.settings.external_network_id
  storage_network_id  = local.settings.storage_network_id

  image_name     = local.settings.image_name
  flavor_name    = local.bootstrap.application_flavor_name
  public_key     = local.bootstrap.ssh.public_key
  instance_count = local.settings.moodle_instance_count
  data_disk_size = local.settings.data_disk_size_gb

  load_balancer_flavor_id = local.bootstrap.load_balancer_flavor_id
  manila_share_type       = local.settings.manila_share_type
  file_share_size         = local.settings.file_share_size_gb
}

module "developer_1" {
  source = "../modules/rhosp-developer-env"
  count  = local.slot_slugs[1] == "" ? 0 : 1

  providers = { openstack = openstack.developer_1 }

  slug                  = local.slot_slugs[1]
  display_name          = var.developers[local.slot_slugs[1]].display_name
  name_prefix           = local.name_prefix
  project_id            = local.bootstrap.developer_projects[local.slot_slugs[1]].id
  management_project_id = local.bootstrap.management_project.id

  tags = [
    "project=${var.project_name}",
    "environment=${local.settings.environment}",
    "managed_by=terraform",
    "owner=${var.developers[local.slot_slugs[1]].username}",
  ]
  metadata = {
    project     = var.project_name
    environment = local.settings.environment
    managed_by  = "terraform"
    owner       = var.developers[local.slot_slugs[1]].username
    role        = "moodle-app"
  }

  subnet_cidr         = var.developers[local.slot_slugs[1]].subnet_app_cidr
  dns_nameservers     = local.settings.dns_nameservers
  external_network_id = local.settings.external_network_id
  storage_network_id  = local.settings.storage_network_id

  image_name     = local.settings.image_name
  flavor_name    = local.bootstrap.application_flavor_name
  public_key     = local.bootstrap.ssh.public_key
  instance_count = local.settings.moodle_instance_count
  data_disk_size = local.settings.data_disk_size_gb

  load_balancer_flavor_id = local.bootstrap.load_balancer_flavor_id
  manila_share_type       = local.settings.manila_share_type
  file_share_size         = local.settings.file_share_size_gb
}

module "developer_2" {
  source = "../modules/rhosp-developer-env"
  count  = local.slot_slugs[2] == "" ? 0 : 1

  providers = { openstack = openstack.developer_2 }

  slug                  = local.slot_slugs[2]
  display_name          = var.developers[local.slot_slugs[2]].display_name
  name_prefix           = local.name_prefix
  project_id            = local.bootstrap.developer_projects[local.slot_slugs[2]].id
  management_project_id = local.bootstrap.management_project.id

  tags = [
    "project=${var.project_name}",
    "environment=${local.settings.environment}",
    "managed_by=terraform",
    "owner=${var.developers[local.slot_slugs[2]].username}",
  ]
  metadata = {
    project     = var.project_name
    environment = local.settings.environment
    managed_by  = "terraform"
    owner       = var.developers[local.slot_slugs[2]].username
    role        = "moodle-app"
  }

  subnet_cidr         = var.developers[local.slot_slugs[2]].subnet_app_cidr
  dns_nameservers     = local.settings.dns_nameservers
  external_network_id = local.settings.external_network_id
  storage_network_id  = local.settings.storage_network_id

  image_name     = local.settings.image_name
  flavor_name    = local.bootstrap.application_flavor_name
  public_key     = local.bootstrap.ssh.public_key
  instance_count = local.settings.moodle_instance_count
  data_disk_size = local.settings.data_disk_size_gb

  load_balancer_flavor_id = local.bootstrap.load_balancer_flavor_id
  manila_share_type       = local.settings.manila_share_type
  file_share_size         = local.settings.file_share_size_gb
}

locals {
  // Collapse the occupied slots back into a map keyed by slug. The key
  // expression is never evaluated for an empty slot, because the module list
  // it iterates is empty.
  developer_environments = merge(
    { for environment in module.developer_0 : local.slot_slugs[0] => environment },
    { for environment in module.developer_1 : local.slot_slugs[1] => environment },
    { for environment in module.developer_2 : local.slot_slugs[2] => environment },
  )
}

// ----------------------------------------------------------------------------
// Management project: the multihomed jump host and the only floating IP
// ----------------------------------------------------------------------------
data "openstack_images_image_v2" "os" {
  name        = local.settings.image_name
  most_recent = true
}

resource "openstack_compute_keypair_v2" "jump" {
  name       = "key-${local.name_prefix}-jump"
  public_key = local.bootstrap.ssh.public_key
}

resource "openstack_networking_network_v2" "management" {
  name           = "net-${local.name_prefix}-mgmt"
  admin_state_up = true
  tenant_id      = local.bootstrap.management_project.id
  tags           = local.management_tags
}

resource "openstack_networking_subnet_v2" "management" {
  name            = "subnet-${local.name_prefix}-mgmt"
  network_id      = openstack_networking_network_v2.management.id
  cidr            = local.settings.mgmt_cidr
  ip_version      = 4
  enable_dhcp     = true
  dns_nameservers = local.settings.dns_nameservers
  tenant_id       = local.bootstrap.management_project.id
  tags            = local.management_tags
}

resource "openstack_networking_router_v2" "management" {
  name                = "router-${local.name_prefix}-mgmt"
  admin_state_up      = true
  external_network_id = local.settings.external_network_id
  enable_snat         = true
  tenant_id           = local.bootstrap.management_project.id
  tags                = local.management_tags
}

resource "openstack_networking_router_interface_v2" "management" {
  router_id = openstack_networking_router_v2.management.id
  subnet_id = openstack_networking_subnet_v2.management.id
}

resource "openstack_networking_secgroup_v2" "public_jump" {
  name        = "sg-${local.name_prefix}-jump"
  description = "SSH entry point and egress from the multihomed jump host"
  tenant_id   = local.bootstrap.management_project.id
  tags        = local.management_tags
}

resource "openstack_networking_secgroup_rule_v2" "public_jump_ssh" {
  security_group_id = openstack_networking_secgroup_v2.public_jump.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = local.settings.admin_source_ip
  tenant_id         = local.bootstrap.management_project.id
  description       = "SSH from the RH Academy workstation only"
}

resource "openstack_networking_port_v2" "management" {
  name                  = "port-${local.name_prefix}-jump-public"
  network_id            = openstack_networking_network_v2.management.id
  admin_state_up        = true
  port_security_enabled = true
  security_group_ids    = [openstack_networking_secgroup_v2.public_jump.id]
  tenant_id             = local.bootstrap.management_project.id
  tags                  = local.management_tags

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.management.id
    ip_address = cidrhost(local.settings.mgmt_cidr, 10)
  }
}

// One management-owned port inside each developer network. The developer
// module grants exactly this with a project-specific Neutron RBAC policy, so
// the jump host reaches every environment while no route joins two of them.
resource "openstack_networking_port_v2" "developer" {
  for_each = local.developer_environments

  name                  = "port-${local.name_prefix}-jump-${each.key}"
  network_id            = each.value.network_id
  admin_state_up        = true
  port_security_enabled = true
  security_group_ids    = [openstack_networking_secgroup_v2.public_jump.id]
  tenant_id             = local.bootstrap.management_project.id
  tags                  = local.management_tags

  fixed_ip {
    subnet_id  = each.value.subnet_id
    ip_address = each.value.jump_fixed_ip
  }
}

resource "openstack_compute_instance_v2" "jump" {
  name        = "vm-${local.name_prefix}-jump"
  flavor_name = local.settings.jump_flavor_name
  key_pair    = openstack_compute_keypair_v2.jump.name
  tags        = local.management_tags
  metadata    = local.management_metadata

  network {
    port = openstack_networking_port_v2.management.id
  }

  dynamic "network" {
    for_each = openstack_networking_port_v2.developer
    content {
      port = network.value.id
    }
  }

  block_device {
    uuid                  = data.openstack_images_image_v2.os.id
    source_type           = "image"
    destination_type      = "volume"
    volume_size           = 20
    boot_index            = 0
    delete_on_termination = true
  }

  user_data = <<-CLOUDINIT
    #cloud-config
    write_files:
      - path: /etc/ssh/sshd_config.d/60-techsprint.conf
        permissions: "0644"
        content: |
          PasswordAuthentication no
          PermitRootLogin no
          AllowAgentForwarding no
      - path: /etc/sysctl.d/90-techsprint-no-forward.conf
        permissions: "0644"
        content: |
          net.ipv4.ip_forward = 0
      - path: /usr/local/sbin/techsprint-jump-routes
        permissions: "0755"
        content: |
          #!/usr/bin/env bash
          set -euo pipefail
          mgmt_ip="${cidrhost(local.settings.mgmt_cidr, 10)}"
          mgmt_gateway="${cidrhost(local.settings.mgmt_cidr, 1)}"
          mgmt_dev="$(ip -o -4 addr show | awk -v ip="$mgmt_ip" '$4 ~ ("^" ip "/") {print $2; exit}')"
          test -n "$mgmt_dev"
          while read -r dev; do
            if [[ "$dev" != "$mgmt_dev" ]]; then
              ip route del default dev "$dev" 2>/dev/null || true
            fi
          done < <(ip -o link show | awk -F': ' '{split($2, name, "@"); print name[1]}')
          ip route replace default via "$mgmt_gateway" dev "$mgmt_dev"
      - path: /etc/systemd/system/techsprint-jump-routes.service
        permissions: "0644"
        content: |
          [Unit]
          Description=Keep the jump host default route on its management NIC
          Wants=network-online.target
          After=network-online.target
          StartLimitIntervalSec=0

          [Service]
          Type=oneshot
          ExecStart=/usr/local/sbin/techsprint-jump-routes
          RemainAfterExit=yes
          Restart=on-failure
          RestartSec=5

          [Install]
          WantedBy=multi-user.target
    runcmd:
      - [ sysctl, --system ]
      - [ systemctl, enable, --now, techsprint-jump-routes.service ]
      - [ systemctl, restart, sshd ]
    CLOUDINIT
}

resource "openstack_networking_floatingip_v2" "jump" {
  pool      = local.settings.external_network_name
  tenant_id = local.bootstrap.management_project.id
  tags      = local.management_tags
}

resource "openstack_networking_floatingip_associate_v2" "jump" {
  floating_ip = openstack_networking_floatingip_v2.jump.address
  port_id     = openstack_networking_port_v2.management.id
}

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
  }
}

provider "openstack" {
  tenant_id    = var.target_project_id
  system_scope = false
}

locals {
  name_prefix = "${var.settings.project_name}-${var.settings.environment_short}"
  tags = [
    "project=${var.settings.project_name}",
    "environment=${var.settings.environment}",
    "managed_by=terraform",
    "role=jump-host",
  ]
  metadata = {
    project     = var.settings.project_name
    environment = var.settings.environment
    managed_by  = "terraform"
    role        = "jump-host"
  }
}

data "openstack_images_image_v2" "os" {
  name        = var.settings.image_name
  most_recent = true
}

resource "openstack_compute_keypair_v2" "jump" {
  name       = "key-${local.name_prefix}-jump"
  public_key = var.ssh_public_key
}

resource "openstack_networking_network_v2" "management" {
  name           = "net-${local.name_prefix}-mgmt"
  admin_state_up = true
  tenant_id      = var.target_project_id
  tags           = local.tags
}

resource "openstack_networking_subnet_v2" "management" {
  name            = "subnet-${local.name_prefix}-mgmt"
  network_id      = openstack_networking_network_v2.management.id
  cidr            = var.settings.mgmt_cidr
  ip_version      = 4
  enable_dhcp     = true
  dns_nameservers = var.settings.dns_nameservers
  tenant_id       = var.target_project_id
  tags            = local.tags
}

resource "openstack_networking_router_v2" "management" {
  name                = "router-${local.name_prefix}-mgmt"
  admin_state_up      = true
  external_network_id = var.settings.external_network_id
  enable_snat         = true
  tenant_id           = var.target_project_id
  tags                = local.tags
}

resource "openstack_networking_router_interface_v2" "management" {
  router_id = openstack_networking_router_v2.management.id
  subnet_id = openstack_networking_subnet_v2.management.id
}

resource "openstack_networking_secgroup_v2" "public_jump" {
  name        = "sg-${local.name_prefix}-jump"
  description = "SSH entry point and egress from the multihomed jump host"
  tenant_id   = var.target_project_id
  tags        = local.tags
}

resource "openstack_networking_secgroup_rule_v2" "public_jump_ssh" {
  security_group_id = openstack_networking_secgroup_v2.public_jump.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.settings.admin_source_ip
  tenant_id         = var.target_project_id
  description       = "SSH from the RH Academy workstation only"
}

resource "openstack_networking_port_v2" "management" {
  name                  = "port-${local.name_prefix}-jump-public"
  network_id            = openstack_networking_network_v2.management.id
  admin_state_up        = true
  port_security_enabled = true
  security_group_ids    = [openstack_networking_secgroup_v2.public_jump.id]
  tenant_id             = var.target_project_id
  tags                  = local.tags

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.management.id
    ip_address = cidrhost(var.settings.mgmt_cidr, 10)
  }
}

// This exact cross-project port ownership path was proven by the bounded
// control-plane probe before implementation.
resource "openstack_networking_port_v2" "developer" {
  for_each = var.developer_networks

  name                  = "port-${local.name_prefix}-jump-${each.key}"
  network_id            = each.value.network_id
  admin_state_up        = true
  port_security_enabled = true
  security_group_ids    = [openstack_networking_secgroup_v2.public_jump.id]
  tenant_id             = var.target_project_id
  tags                  = local.tags

  fixed_ip {
    subnet_id  = each.value.subnet_id
    ip_address = each.value.jump_fixed_ip
  }
}

resource "openstack_compute_instance_v2" "jump" {
  name        = "vm-${local.name_prefix}-jump"
  flavor_name = var.settings.jump_flavor_name
  key_pair    = openstack_compute_keypair_v2.jump.name
  tags        = local.tags
  metadata    = local.metadata

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
          mgmt_ip="${cidrhost(var.settings.mgmt_cidr, 10)}"
          mgmt_gateway="${cidrhost(var.settings.mgmt_cidr, 1)}"
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
  pool      = var.settings.external_network_name
  tenant_id = var.target_project_id
  tags      = local.tags
}

resource "openstack_networking_floatingip_associate_v2" "jump" {
  floating_ip = openstack_networking_floatingip_v2.jump.address
  port_id     = openstack_networking_port_v2.management.id
}

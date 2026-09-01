terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
  }
}

locals {
  env_name       = "${var.name_prefix}-${var.slug}"
  jump_fixed_ip  = cidrhost(var.subnet_cidr, 253)
  load_balancer  = cidrhost(var.subnet_cidr, 250)
  cephx_username = "techsprint-${var.slug}"
}

data "openstack_images_image_v2" "os" {
  name        = var.image_name
  most_recent = true
}

resource "openstack_compute_keypair_v2" "environment" {
  name       = "key-${local.env_name}"
  public_key = var.public_key
}

// ---------------------------------------------------------------------------
// Developer-owned network, outbound router, and narrow management RBAC grant
// ---------------------------------------------------------------------------
resource "openstack_networking_network_v2" "environment" {
  name           = "net-${local.env_name}"
  admin_state_up = true
  tenant_id      = var.project_id
  tags           = var.tags
}

resource "openstack_networking_subnet_v2" "application" {
  name            = "subnet-${local.env_name}-app"
  network_id      = openstack_networking_network_v2.environment.id
  cidr            = var.subnet_cidr
  ip_version      = 4
  enable_dhcp     = true
  dns_nameservers = var.dns_nameservers
  tenant_id       = var.project_id
  tags            = var.tags
}

resource "openstack_networking_router_v2" "environment" {
  name                = "router-${local.env_name}"
  admin_state_up      = true
  external_network_id = var.external_network_id
  enable_snat         = true
  tenant_id           = var.project_id
  tags                = var.tags
}

resource "openstack_networking_router_interface_v2" "application" {
  router_id = openstack_networking_router_v2.environment.id
  subnet_id = openstack_networking_subnet_v2.application.id
}

// Proven in the RHOSP control-plane probe: after this project-specific grant,
// the management project can create and own a port on this private network.
resource "openstack_networking_rbac_policy_v2" "management_access" {
  action        = "access_as_shared"
  object_id     = openstack_networking_network_v2.environment.id
  object_type   = "network"
  target_tenant = var.management_project_id
}

// ---------------------------------------------------------------------------
// Application security group
// ---------------------------------------------------------------------------
resource "openstack_networking_secgroup_v2" "application" {
  name                 = "sg-${local.env_name}-moodle"
  description          = "Moodle nodes for ${var.display_name}"
  delete_default_rules = true
  tenant_id            = var.project_id
  tags                 = var.tags
}

resource "openstack_networking_secgroup_rule_v2" "application_egress" {
  security_group_id = openstack_networking_secgroup_v2.application.id
  direction         = "egress"
  ethertype         = "IPv4"
  remote_ip_prefix  = "0.0.0.0/0"
  tenant_id         = var.project_id
  description       = "Package downloads, Swift, and service APIs"
}

resource "openstack_networking_secgroup_rule_v2" "ssh_from_jump" {
  security_group_id = openstack_networking_secgroup_v2.application.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "${local.jump_fixed_ip}/32"
  tenant_id         = var.project_id
  description       = "Only this environment's management-owned jump port"
}

resource "openstack_networking_secgroup_rule_v2" "http_from_environment" {
  security_group_id = openstack_networking_secgroup_v2.application.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = var.subnet_cidr
  tenant_id         = var.project_id
  description       = "Amphora traffic and HTTP health checks"
}

resource "openstack_networking_secgroup_rule_v2" "database_between_nodes" {
  security_group_id = openstack_networking_secgroup_v2.application.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 3306
  port_range_max    = 3306
  remote_group_id   = openstack_networking_secgroup_v2.application.id
  tenant_id         = var.project_id
  description       = "MariaDB only between this developer's Moodle nodes"
}

// ---------------------------------------------------------------------------
// Two application VMs, each with a boot volume and a separate data volume
// ---------------------------------------------------------------------------
resource "openstack_networking_port_v2" "application" {
  count = var.instance_count

  name                  = "port-${local.env_name}-moodle-${count.index + 1}"
  network_id            = openstack_networking_network_v2.environment.id
  admin_state_up        = true
  port_security_enabled = true
  security_group_ids    = [openstack_networking_secgroup_v2.application.id]
  tenant_id             = var.project_id
  tags                  = var.tags

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.application.id
    ip_address = cidrhost(var.subnet_cidr, 10 + count.index)
  }
}

resource "openstack_networking_port_v2" "storage" {
  count = var.instance_count

  name                  = "port-${local.env_name}-moodle-${count.index + 1}-storage"
  network_id            = var.storage_network_id
  admin_state_up        = true
  port_security_enabled = true
  security_group_ids    = [openstack_networking_secgroup_v2.application.id]
  tenant_id             = var.project_id
  tags                  = var.tags
}

resource "openstack_compute_instance_v2" "moodle" {
  count = var.instance_count

  name        = "vm-${local.env_name}-moodle-${count.index + 1}"
  flavor_name = var.flavor_name
  key_pair    = openstack_compute_keypair_v2.environment.name
  tags        = var.tags
  metadata = merge(var.metadata, {
    instance  = tostring(count.index + 1)
    owner_env = var.slug
  })

  network {
    port = openstack_networking_port_v2.application[count.index].id
  }

  network {
    port = openstack_networking_port_v2.storage[count.index].id
  }

  block_device {
    uuid                  = data.openstack_images_image_v2.os.id
    source_type           = "image"
    destination_type      = "volume"
    volume_size           = 20
    boot_index            = 0
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    node_index      = count.index + 1
    primary_ip      = openstack_networking_port_v2.application[count.index].all_fixed_ips[0]
    primary_gateway = cidrhost(var.subnet_cidr, 1)
  })

  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "openstack_blockstorage_volume_v3" "data" {
  count = var.instance_count

  name        = "vol-${local.env_name}-moodle-${count.index + 1}-data"
  description = "Required second disk for ${var.display_name}, node ${count.index + 1}"
  size        = var.data_disk_size
  metadata    = var.metadata
}

resource "openstack_compute_volume_attach_v2" "data" {
  count = var.instance_count

  instance_id = openstack_compute_instance_v2.moodle[count.index].id
  volume_id   = openstack_blockstorage_volume_v3.data[count.index].id
}

// ---------------------------------------------------------------------------
// Managed Amphora SINGLE load balancer with HTTP health monitoring
// ---------------------------------------------------------------------------

resource "openstack_lb_loadbalancer_v2" "moodle" {
  name               = "lb-${local.env_name}-moodle"
  description        = "Private Moodle load balancer for ${var.display_name}"
  vip_subnet_id      = openstack_networking_subnet_v2.application.id
  vip_address        = local.load_balancer
  flavor_id          = var.load_balancer_flavor_id
  security_group_ids = [openstack_networking_secgroup_v2.application.id]
  tenant_id          = var.project_id
  tags               = var.tags
}

resource "openstack_lb_listener_v2" "http" {
  name            = "listener-${local.env_name}-http"
  protocol        = "HTTP"
  protocol_port   = 80
  loadbalancer_id = openstack_lb_loadbalancer_v2.moodle.id
}

resource "openstack_lb_pool_v2" "moodle" {
  name        = "pool-${local.env_name}-moodle"
  protocol    = "HTTP"
  listener_id = openstack_lb_listener_v2.http.id
  lb_method   = "SOURCE_IP"
}

resource "openstack_lb_member_v2" "moodle" {
  count = var.instance_count

  pool_id       = openstack_lb_pool_v2.moodle.id
  address       = openstack_networking_port_v2.application[count.index].all_fixed_ips[0]
  protocol_port = 80
  subnet_id     = openstack_networking_subnet_v2.application.id
}

resource "openstack_lb_monitor_v2" "moodle" {
  name           = "monitor-${local.env_name}-http"
  pool_id        = openstack_lb_pool_v2.moodle.id
  type           = "HTTP"
  url_path       = "/healthz.php"
  expected_codes = "200"
  delay          = 15
  timeout        = 5
  max_retries    = 2
}

// ---------------------------------------------------------------------------
// Object storage mounted by rclone and file storage mounted by native CephFS
// ---------------------------------------------------------------------------
resource "openstack_objectstorage_container_v1" "moodle_files" {
  name          = "cont-${local.env_name}-moodle-files"
  content_type  = "application/octet-stream"
  force_destroy = true

  metadata = {
    project     = var.metadata.project
    environment = var.metadata.environment
    owner       = var.slug
  }
}

resource "openstack_sharedfilesystem_share_v2" "backups" {
  name        = "share-${local.env_name}-backups"
  description = "Moodle backups for ${var.display_name}"
  share_proto = "CEPHFS"
  share_type  = var.manila_share_type
  size        = var.file_share_size
  is_public   = false
  metadata    = var.metadata
}

resource "openstack_sharedfilesystem_share_access_v2" "backups" {
  share_id     = openstack_sharedfilesystem_share_v2.backups.id
  access_type  = "cephx"
  access_to    = local.cephx_username
  access_level = "rw"
}

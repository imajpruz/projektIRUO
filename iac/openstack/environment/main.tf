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
  developer   = var.developer
  name_prefix = "${var.settings.project_name}-${var.settings.environment_short}"
  tags = [
    "project=${var.settings.project_name}",
    "environment=${var.settings.environment}",
    "managed_by=terraform",
    "owner=${local.developer.username}",
  ]
  metadata = {
    project     = var.settings.project_name
    environment = var.settings.environment
    managed_by  = "terraform"
    owner       = local.developer.username
    role        = "moodle-app"
  }
}

module "environment" {
  source = "../modules/rhosp-developer-env"

  slug                  = var.target_slug
  display_name          = local.developer.display_name
  name_prefix           = local.name_prefix
  project_id            = var.target_project_id
  management_project_id = var.management_project_id
  tags                  = local.tags
  metadata              = local.metadata

  subnet_cidr         = local.developer.subnet_app_cidr
  dns_nameservers     = var.settings.dns_nameservers
  external_network_id = var.settings.external_network_id
  storage_network_id  = var.settings.storage_network_id

  image_name     = var.settings.image_name
  flavor_name    = var.application_flavor_name
  public_key     = var.ssh_public_key
  instance_count = var.settings.moodle_instance_count
  data_disk_size = var.settings.data_disk_size_gb

  load_balancer_flavor_id = var.load_balancer_flavor_id
  manila_share_type       = var.settings.manila_share_type
  file_share_size         = var.settings.file_share_size_gb
}

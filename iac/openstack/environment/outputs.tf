output "environment" {
  value = {
    project_id         = var.target_project_id
    project_name       = var.target_project_name
    network_id         = module.environment.network_id
    subnet_id          = module.environment.subnet_id
    subnet_cidr        = module.environment.subnet_cidr
    jump_fixed_ip      = module.environment.jump_fixed_ip
    moodle_instances   = module.environment.moodle_instance_names
    moodle_private_ips = module.environment.moodle_private_ips
    load_balancer      = module.environment.load_balancer_address
    object_container   = module.environment.object_container
    file_share_export  = module.environment.file_share_export
  }
}

output "management_attachment" {
  description = "Consumed by the management root to multihome the central jump VM"
  value = {
    network_id    = module.environment.network_id
    subnet_id     = module.environment.subnet_id
    jump_fixed_ip = module.environment.jump_fixed_ip
  }
}

output "inventory_data" {
  sensitive = true
  value = {
    slug                  = var.target_slug
    display_name          = var.developer.display_name
    project_id            = var.target_project_id
    project_name          = var.target_project_name
    identity_domain       = var.identity_domain_name
    subnet_cidr           = module.environment.subnet_cidr
    moodle_ips            = module.environment.moodle_private_ips
    database_password     = var.database_password
    moodle_admin_password = var.moodle_admin_password
    load_balancer         = module.environment.load_balancer_address
    object_auth_url       = var.object_auth_url
    object_username       = var.object_username
    object_password       = var.object_password
    object_container      = module.environment.object_container
    file_share_export     = module.environment.file_share_export
    file_share_user       = module.environment.file_share_user
    file_share_key        = module.environment.file_share_key
  }
}

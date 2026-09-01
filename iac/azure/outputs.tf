// Outputs are the handover to Ansible and to the person running the demo.
// deploy.sh reads inventory_data to build the Ansible inventory, so no address
// is ever typed by hand.

output "jump_host_public_ip" {
  description = "The single public entry point. Every SSH session proxies through here."
  value       = module.hub.jump_public_ip
}

output "ssh_private_key_path" {
  description = "Generated key, written with 0600. Gitignored."
  value       = local_sensitive_file.ssh_private_key.filename
}

output "ssh_config_snippet" {
  description = "Append to ~/.ssh/config to reach any node by name through the bastion"
  value = join("\n", concat([
    "Host techsprint-jump",
    "  HostName ${module.hub.jump_public_ip}",
    "  User ${var.admin_username}",
    "  IdentityFile ${abspath(local_sensitive_file.ssh_private_key.filename)}",
    "  StrictHostKeyChecking accept-new",
    "",
    ], flatten([
      for slug, env in module.developer_env : [
        for idx, ip in env.moodle_private_ips : join("\n", [
          "Host ${slug}-moodle-${idx + 1}",
          "  HostName ${ip}",
          "  User ${var.admin_username}",
          "  IdentityFile ${abspath(local_sensitive_file.ssh_private_key.filename)}",
          "  ProxyJump techsprint-jump",
          "  StrictHostKeyChecking accept-new",
          "",
        ])
      ]
  ])))
}

output "environments" {
  description = "One block per developer, for the report and the demo walkthrough"
  value = {
    for slug, env in module.developer_env : slug => {
      owner                  = var.developers[slug].username
      resource_group         = env.resource_group_name
      location               = env.location
      vnet_cidr              = env.vnet_cidr
      moodle_instances       = env.moodle_vm_names
      moodle_private_ips     = env.moodle_private_ips
      load_balancer_name     = env.load_balancer_name
      load_balancer          = env.load_balancer_private_ip
      moodle_url_via_bastion = "http://${env.load_balancer_private_ip}  (through: ssh -D 1080 techsprint-jump)"
      blob_storage_account   = env.blob_storage_account_name
      file_storage_account   = env.file_storage_account_name
      blob_container         = env.blob_container_name
      file_share             = env.file_share_name
    }
  }
}

output "inventory_data" {
  description = "Consumed by deploy.sh to render the Ansible inventory"
  sensitive   = true
  value = {
    jump_host          = module.hub.jump_public_ip
    hub_resource_group = module.hub.resource_group_name
    admin_username     = var.admin_username
    ssh_key            = abspath(local_sensitive_file.ssh_private_key.filename)
    environments = {
      for slug, env in module.developer_env : slug => {
        display_name          = var.developers[slug].display_name
        moodle_ips            = env.moodle_private_ips
        subnet_cidr           = env.subnet_app_cidr
        resource_group        = env.resource_group_name
        load_balancer_name    = env.load_balancer_name
        blob_storage_account  = env.blob_storage_account_name
        file_storage_account  = env.file_storage_account_name
        file_storage_key      = env.file_storage_account_key
        blob_container        = env.blob_container_name
        file_share            = env.file_share_name
        identity_client_id    = env.managed_identity_client_id
        load_balancer         = env.load_balancer_private_ip
        database_password     = random_password.moodle_db[slug].result
        moodle_admin_password = random_password.moodle_admin[slug].result
      }
    }
  }
}

output "identity_summary" {
  description = "CSV-driven application identities and their least-privilege scopes"
  value = {
    custom_role = azurerm_role_definition.vm_power_operator.name
    developers = {
      for slug, dev in var.developers : slug => {
        identity_type = "service_principal"
        client_id     = azuread_application_registration.identity[slug].client_id
        scope         = module.developer_env[slug].resource_group_name
        rights        = "start / restart / deallocate + read, own resource group only"
      }
    }
    leads = {
      for slug, lead in var.leads : slug => {
        identity_type = "service_principal"
        client_id     = azuread_application_registration.identity[slug].client_id
        scope         = "all TechSprint resource groups"
        rights        = "start / restart / deallocate + read, TechSprint resources only"
      }
    }
  }
}

output "initial_credentials" {
  description = "Service-principal demo credentials. Retrieve only when testing RBAC."
  value = {
    for slug, identity in azuread_application_registration.identity : slug => {
      client_id     = identity.client_id
      client_secret = azuread_application_password.identity[slug].value
      tenant_id     = var.tenant_id
      login_hint    = "az login --service-principal --username <client_id> --password <client_secret> --tenant <tenant_id>"
    }
  }
  sensitive = true
}

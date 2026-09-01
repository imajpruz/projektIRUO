output "resource_group_name" {
  value = azurerm_resource_group.env.name
}

output "resource_group_id" {
  description = "RBAC scope for this developer's power-operator assignment"
  value       = azurerm_resource_group.env.id
}

output "vnet_cidr" {
  value = var.vnet_cidr
}

output "subnet_app_cidr" {
  value = var.subnet_app_cidr
}

output "location" {
  value = azurerm_resource_group.env.location
}

output "moodle_private_ips" {
  description = "Reachable only through the bastion; consumed by the Ansible inventory"
  value       = azurerm_network_interface.moodle[*].private_ip_address
}

output "moodle_vm_names" {
  value = azurerm_linux_virtual_machine.moodle[*].name
}

output "load_balancer_private_ip" {
  description = "Moodle's entry point inside this developer's network"
  value       = azurerm_lb.moodle.frontend_ip_configuration[0].private_ip_address
}

output "load_balancer_name" {
  value = azurerm_lb.moodle.name
}

output "blob_storage_account_name" {
  value = azurerm_storage_account.blob.name
}

output "file_storage_account_name" {
  value = azurerm_storage_account.files.name
}

output "blob_container_name" {
  value = azurerm_storage_container.moodle_files.name
}

output "file_share_name" {
  value = azurerm_storage_share.backups.name
}

output "managed_identity_client_id" {
  description = "Passed to the VMs so the Azure SDK can pick the right identity"
  value       = azurerm_user_assigned_identity.moodle.client_id
}

output "file_storage_account_key" {
  description = "Needed to mount the SMB file share; never written to the repo"
  value       = azurerm_storage_account.files.primary_access_key
  sensitive   = true
}

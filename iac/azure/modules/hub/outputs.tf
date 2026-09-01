output "resource_group_name" {
  value = azurerm_resource_group.hub.name
}

output "resource_group_id" {
  value = azurerm_resource_group.hub.id
}

output "vnet_id" {
  description = "Consumed by each developer module to build its peering back to the hub"
  value       = azurerm_virtual_network.hub.id
}

output "vnet_name" {
  value = azurerm_virtual_network.hub.name
}

output "jump_public_ip" {
  description = "The single public entry point to the whole environment"
  value       = azurerm_public_ip.jump.ip_address
}

output "jump_private_ip" {
  value = azurerm_network_interface.jump.private_ip_address
}

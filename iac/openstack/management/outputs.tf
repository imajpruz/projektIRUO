output "jump_host_floating_ip" {
  description = "The only public address in the OpenStack deployment"
  value       = openstack_networking_floatingip_v2.jump.address
}

output "inventory_data" {
  value = {
    jump_host       = openstack_networking_floatingip_v2.jump.address
    jump_private_ip = openstack_networking_port_v2.management.all_fixed_ips[0]
    admin_username  = var.settings.admin_username
  }
}

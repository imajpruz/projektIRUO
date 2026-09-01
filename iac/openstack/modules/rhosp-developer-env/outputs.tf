output "network_id" {
  value = openstack_networking_network_v2.environment.id
}

output "subnet_id" {
  value = openstack_networking_subnet_v2.application.id
}

output "subnet_cidr" {
  value = var.subnet_cidr
}

output "jump_fixed_ip" {
  value = local.jump_fixed_ip
}

output "moodle_instance_names" {
  value = openstack_compute_instance_v2.moodle[*].name
}

output "moodle_private_ips" {
  value = [for port in openstack_networking_port_v2.application : port.all_fixed_ips[0]]
}

output "load_balancer_address" {
  value = openstack_lb_loadbalancer_v2.moodle.vip_address
}

output "object_container" {
  value = openstack_objectstorage_container_v1.moodle_files.name
}

output "file_share_export" {
  value = openstack_sharedfilesystem_share_v2.backups.export_locations[0].path
}

output "file_share_user" {
  value = local.cephx_username
}

output "file_share_key" {
  value     = openstack_sharedfilesystem_share_access_v2.backups.access_key
  sensitive = true
}

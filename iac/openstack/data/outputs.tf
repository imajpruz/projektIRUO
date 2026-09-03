// A single inventory_data output, in exactly the shape lib/render_inventory.py
// and lib/verify.sh already expect from the Azure root. Because this root now
// holds both the developer environments and the jump host, deploy.sh can run
// one `terraform output -json` per cloud and the merge step that lib/
// openstack_stages.py used to perform is gone.

output "inventory_data" {
  description = "Everything Ansible and the verifier need, from one apply"
  sensitive   = true

  value = {
    jump_host       = openstack_networking_floatingip_v2.jump.address
    jump_private_ip = openstack_networking_port_v2.management.all_fixed_ips[0]
    admin_username  = local.settings.admin_username
    ssh_key         = local.bootstrap.ssh.private_key_path

    environments = {
      for slug, environment in local.developer_environments : slug => {
        display_name     = var.developers[slug].display_name
        project_id       = local.bootstrap.developer_projects[slug].id
        project_name     = local.bootstrap.developer_projects[slug].name
        identity_domain  = local.bootstrap.domain_name
        subnet_cidr      = environment.subnet_cidr
        moodle_instances = environment.moodle_instance_names
        moodle_ips       = environment.moodle_private_ips
        load_balancer    = environment.load_balancer_address

        database_password     = local.secrets[slug].database_password
        moodle_admin_password = local.secrets[slug].moodle_admin_password

        object_container = environment.object_container
        object_auth_url  = var.object_auth_url
        object_username  = local.secrets[slug].object_username
        object_password  = local.secrets[slug].object_password

        file_share_export = environment.file_share_export
        file_share_user   = environment.file_share_user
        file_share_key    = environment.file_share_key
      }
    }
  }
}

output "jump_host_floating_ip" {
  description = "The only public address in the OpenStack deployment"
  value       = openstack_networking_floatingip_v2.jump.address
}

output "environments" {
  description = "Non-secret per-developer summary, for the report and screenshots"
  value = {
    for slug, environment in local.developer_environments : slug => {
      project_name     = local.bootstrap.developer_projects[slug].name
      network_id       = environment.network_id
      subnet_cidr      = environment.subnet_cidr
      jump_fixed_ip    = environment.jump_fixed_ip
      moodle_instances = environment.moodle_instance_names
      moodle_ips       = environment.moodle_private_ips
      load_balancer    = environment.load_balancer_address
      object_container = environment.object_container
    }
  }
}

output "ssh_config_snippet" {
  description = "Named SSH hosts for every Moodle node, proxied through the jump host"
  value = join("\n", concat(
    [
      "Host techsprint-openstack-jump",
      "  HostName ${openstack_networking_floatingip_v2.jump.address}",
      "  User ${local.settings.admin_username}",
      "  IdentityFile ${local.bootstrap.ssh.private_key_path}",
      "  StrictHostKeyChecking accept-new",
      "",
    ],
    flatten([
      for slug, environment in local.developer_environments : [
        for index, address in environment.moodle_private_ips : join("\n", [
          "Host ${slug}-moodle-${index + 1}",
          "  HostName ${address}",
          "  User ${local.settings.admin_username}",
          "  IdentityFile ${local.bootstrap.ssh.private_key_path}",
          "  ProxyJump techsprint-openstack-jump",
          "  StrictHostKeyChecking accept-new",
          "",
        ])
      ]
    ])
  ))
}

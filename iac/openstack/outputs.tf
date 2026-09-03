// Published split by sensitivity, because sensitivity propagates through
// terraform_remote_state: if ids, names and settings shared one output with the
// generated credentials, every output data/ derives from them would have to be
// marked sensitive too, and the per-developer summary would print as
// "(sensitive value)".

output "bootstrap_public" {
  description = "Non-secret project ids, flavors and lab settings consumed by data/"
  value = {
    domain_name = openstack_identity_project_v3.domain.name
    management_project = {
      id   = openstack_identity_project_v3.management.id
      name = openstack_identity_project_v3.management.name
    }
    developer_projects = {
      for slug, project in openstack_identity_project_v3.developer : slug => {
        id   = project.id
        name = project.name
      }
    }
    application_flavor_name = openstack_compute_flavor_v2.moodle.name
    load_balancer_flavor_id = openstack_lb_flavor_v2.single_amphora.id
    ssh = {
      private_key_path = abspath(local_sensitive_file.ssh_private_key.filename)
      public_key       = tls_private_key.techsprint.public_key_openssh
    }
    settings = {
      project_name          = var.project_name
      environment           = var.environment
      environment_short     = var.environment_short
      external_network_id   = var.external_network_id
      external_network_name = var.external_network_name
      storage_network_id    = var.storage_network_id
      image_name            = var.image_name
      jump_flavor_name      = var.jump_flavor_name
      mgmt_cidr             = var.mgmt_cidr
      dns_nameservers       = var.dns_nameservers
      admin_source_ip       = var.admin_source_ip
      admin_username        = var.admin_username
      moodle_instance_count = var.moodle_instance_count
      data_disk_size_gb     = var.data_disk_size_gb
      file_share_size_gb    = var.file_share_size_gb
      manila_share_type     = var.manila_share_type
    }
  }
}

output "bootstrap_secrets" {
  description = "Generated per-environment credentials consumed by data/"
  sensitive   = true
  value = {
    for slug, developer in var.developers : slug => {
      database_password     = random_password.database[slug].result
      moodle_admin_password = random_password.moodle_admin[slug].result
      object_username       = openstack_identity_user_v3.object_storage[slug].name
      object_password       = random_password.object_storage[slug].result
    }
  }
}

output "identity_summary" {
  description = "Keystone domain, projects, groups, users, and role scopes"
  value = {
    domain             = openstack_identity_project_v3.domain.name
    leads_group        = openstack_identity_group_v3.leads.name
    management_project = openstack_identity_project_v3.management.name
    developers = {
      for slug, developer in var.developers : slug => {
        username             = openstack_identity_user_v3.developer[slug].name
        group                = openstack_identity_group_v3.developer[slug].name
        project              = openstack_identity_project_v3.developer[slug].name
        swift_mount_identity = openstack_identity_user_v3.object_storage[slug].name
        rights               = "member and swiftoperator in own project only"
      }
    }
    leads = {
      for slug, lead in var.leads : slug => {
        username = openstack_identity_user_v3.lead[slug].name
        group    = openstack_identity_group_v3.leads.name
        rights   = "member and swiftoperator in every developer project; member in management"
      }
    }
  }
}

output "initial_passwords" {
  description = "First human sign-in passwords; never paste these into evidence"
  value = merge(
    { for slug, developer in var.developers : openstack_identity_user_v3.developer[slug].name => random_password.user[slug].result },
    { for slug, lead in var.leads : openstack_identity_user_v3.lead[slug].name => random_password.user[slug].result },
  )
  sensitive = true
}

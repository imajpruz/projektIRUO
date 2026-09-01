variable "developer" {
  type = object({
    display_name    = string
    username        = string
    subnet_app_cidr = string
  })
}

variable "target_slug" {
  type = string
}

variable "target_project_id" {
  type = string
}

variable "target_project_name" {
  type = string
}

variable "management_project_id" {
  type = string
}

variable "identity_domain_name" {
  type = string
}

variable "application_flavor_name" {
  type = string
}

variable "load_balancer_flavor_id" {
  type = string
}

variable "ssh_public_key" {
  type      = string
  sensitive = true
}

variable "database_password" {
  type      = string
  sensitive = true
}

variable "moodle_admin_password" {
  type      = string
  sensitive = true
}

variable "object_auth_url" {
  type = string
}

variable "object_username" {
  type = string
}

variable "object_password" {
  type      = string
  sensitive = true
}

variable "settings" {
  description = "Shared non-secret deployment settings from the bootstrap root"
  type = object({
    project_name          = string
    environment           = string
    environment_short     = string
    external_network_id   = string
    storage_network_id    = string
    image_name            = string
    dns_nameservers       = list(string)
    moodle_instance_count = number
    data_disk_size_gb     = number
    file_share_size_gb    = number
    manila_share_type     = string
  })
}

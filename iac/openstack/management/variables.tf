variable "target_project_id" {
  type = string
}

variable "developer_networks" {
  type = map(object({
    network_id    = string
    subnet_id     = string
    jump_fixed_ip = string
  }))
}

variable "ssh_public_key" {
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
    external_network_name = string
    image_name            = string
    jump_flavor_name      = string
    mgmt_cidr             = string
    dns_nameservers       = list(string)
    admin_source_ip       = string
    admin_username        = string
  })
}

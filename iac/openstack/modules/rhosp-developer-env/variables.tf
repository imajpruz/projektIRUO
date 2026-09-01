variable "slug" {
  type = string
}

variable "display_name" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "project_id" {
  type = string
}

variable "management_project_id" {
  type = string
}

variable "tags" {
  type = list(string)
}

variable "metadata" {
  type = map(string)
}

variable "subnet_cidr" {
  type = string
}

variable "dns_nameservers" {
  type = list(string)
}

variable "external_network_id" {
  type = string
}

variable "storage_network_id" {
  description = "Shared provider-storage network used by native CephFS clients"
  type        = string
}

variable "image_name" {
  type = string
}

variable "flavor_name" {
  type = string
}

variable "public_key" {
  type      = string
  sensitive = true
}

variable "instance_count" {
  type    = number
  default = 2
}

variable "data_disk_size" {
  type = number
}

variable "load_balancer_flavor_id" {
  type = string
}

variable "manila_share_type" {
  type = string
}

variable "file_share_size" {
  type    = number
  default = 5
}

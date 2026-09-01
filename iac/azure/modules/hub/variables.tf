variable "name_prefix" {
  description = "project-environment prefix, e.g. techsprint-test"
  type        = string
}

variable "location" {
  type = string
}

variable "tags" {
  description = "Mandatory project/environment tags plus provenance"
  type        = map(string)
}

variable "vnet_cidr" {
  type = string
}

variable "subnet_cidr" {
  type = string
}

variable "admin_username" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "vm_size" {
  type = string
}

variable "admin_source_ip" {
  description = "The only source allowed to SSH to the bastion"
  type        = string
}

variable "developer_cidrs" {
  description = "slug => VNet CIDR allowed to forward Internet egress through the jump NVA"
  type        = map(string)
}

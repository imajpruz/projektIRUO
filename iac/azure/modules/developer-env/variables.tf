variable "slug" {
  description = "Short unique identifier for this developer, from lib/parse_users.py"
  type        = string
}

variable "name_prefix" {
  description = "project-environment prefix, e.g. techsprint-test"
  type        = string
}

variable "location" {
  type = string
}

variable "tags" {
  description = "Mandatory project/environment tags plus owner and role"
  type        = map(string)
}

// --- network ----------------------------------------------------------------

variable "vnet_cidr" {
  description = "This developer's /16, disjoint from every other developer's"
  type        = string
}

variable "subnet_app_cidr" {
  description = "Subnet holding the Moodle VMs and the internal load balancer"
  type        = string
}

variable "hub_vnet_id" {
  description = "Hub VNet to peer with. The only peering this environment has."
  type        = string
}

variable "hub_vnet_name" {
  type = string
}

variable "hub_rg_name" {
  type = string
}

variable "hub_cidr" {
  description = "Source range allowed to SSH into the Moodle VMs"
  type        = string
}

variable "hub_private_ip" {
  description = "Jump/NVA private address used as the default-route next hop"
  type        = string
}

variable "admin_source_ip_for_storage" {
  description = "Deployment workstation CIDR allowed to create Blob and Files data-plane resources"
  type        = string
}

// --- compute ----------------------------------------------------------------

variable "vm_size" {
  description = "2 vCPU and 4 GB RAM, as the brief requires"
  type        = string
}

variable "vm_count" {
  description = "Moodle application VMs. Two, to simulate high availability."
  type        = number
  default     = 2
}

variable "admin_username" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "data_disk_size" {
  description = "Size of the second managed disk, mounted at /mnt/techsprint-data"
  type        = number
}

variable "os_image" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
}

variable "os_image_requires_plan" {
  description = <<-EOT
    True for marketplace images such as Rocky Linux, which need a matching
    plan block and a one-time terms acceptance. False for first-party images
    such as Ubuntu or Azure Linux, which reject a plan block outright.
  EOT
  type        = bool
  default     = true
}

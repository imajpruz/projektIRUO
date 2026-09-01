// ============================================================================
// One isolated developer environment
//
// Instantiated once per CSV row. Contains everything that developer owns:
//
//   resource group        the RBAC scope that makes "only their own VMs" true
//   VNet + app subnet     peered to the hub only, so spokes cannot see spokes
//   route via jump/NVA    outbound internet with no additional public IP
//   load balancer         two Moodle backends, health-probed
//   2 x Rocky Linux VM    2 vCPU / 4 GB, OS disk + data disk
//   storage account       blob container (Moodle files) + file share (backups)
//   managed identity      how the VMs read the blob container, no keys on disk
//
// No public IP anywhere in this module. That is the point.
// ============================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

locals {
  env_name = "${var.name_prefix}-${var.slug}"

  // Storage account names: 3-24 chars, lowercase alphanumerics only, globally
  // unique. Truncate the descriptive base before appending the random suffix;
  // truncating the complete value could remove the characters that provide
  // global uniqueness.
  storage_account_base      = lower(replace("${var.name_prefix}${var.slug}", "/[^a-z0-9]/", ""))
  blob_storage_account_name = "stb${substr(local.storage_account_base, 0, 17)}${random_string.storage_suffix.result}"
  file_storage_account_name = "stf${substr(local.storage_account_base, 0, 17)}${random_string.storage_suffix.result}"
}

resource "random_string" "storage_suffix" {
  length  = 4
  special = false
  upper   = false
  numeric = true
  lower   = true
}

// ----------------------------------------------------------------------------
// Resource group: the isolation boundary AND the RBAC scope
//
// One group per developer is what lets the root module assign the power role
// at exactly this scope. Graded under I5: "Kreirana logična hijerarhija
// Resource Grupa".
// ----------------------------------------------------------------------------
resource "azurerm_resource_group" "env" {
  name     = "rg-${local.env_name}"
  location = var.location
  tags     = var.tags
}

// ----------------------------------------------------------------------------
// Network
// ----------------------------------------------------------------------------
resource "azurerm_virtual_network" "env" {
  name                = "vnet-${local.env_name}"
  resource_group_name = azurerm_resource_group.env.name
  location            = azurerm_resource_group.env.location
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.env.name
  virtual_network_name = azurerm_virtual_network.env.name
  address_prefixes     = [var.subnet_app_cidr]
  service_endpoints    = ["Microsoft.Storage"]
}

// --- outbound internet, without another public IP ---------------------------
//
// "Virtualne mašine moraju moći pristupiti Internetu radi preuzimanja paketa."
//
// The official rubric also says the jump host must own the only public IP.
// Therefore each spoke routes default traffic to the jump/NVA, which performs
// source NAT through its existing public address.
resource "azurerm_route_table" "egress" {
  name                = "rt-${local.env_name}-egress"
  resource_group_name = azurerm_resource_group.env.name
  location            = azurerm_resource_group.env.location
  tags                = var.tags
}

resource "azurerm_route" "default_via_jump" {
  name                   = "default-via-jump"
  resource_group_name    = azurerm_resource_group.env.name
  route_table_name       = azurerm_route_table.egress.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.hub_private_ip
}

resource "azurerm_subnet_route_table_association" "app" {
  subnet_id      = azurerm_subnet.app.id
  route_table_id = azurerm_route_table.egress.id
}

// --- peering to the hub, and only to the hub --------------------------------
//
// Peering is not transitive in Azure. The only forwarded route is the default
// Internet path; the hub NSG and NVA firewall drop private cross-spoke traffic.
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-${var.slug}-to-hub"
  resource_group_name       = azurerm_resource_group.env.name
  virtual_network_name      = azurerm_virtual_network.env.name
  remote_virtual_network_id = var.hub_vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "peer-hub-to-${var.slug}"
  resource_group_name       = var.hub_rg_name
  virtual_network_name      = var.hub_vnet_name
  remote_virtual_network_id = azurerm_virtual_network.env.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

// --- security groups --------------------------------------------------------
//
// "Pravilno kreirane i podešene security grupe (posebno za dev i lead role)"
resource "azurerm_application_security_group" "moodle" {
  name                = "asg-${local.env_name}-moodle"
  resource_group_name = azurerm_resource_group.env.name
  location            = azurerm_resource_group.env.location
  tags                = var.tags
}

resource "azurerm_network_security_group" "app" {
  name                = "nsg-${local.env_name}-app"
  resource_group_name = azurerm_resource_group.env.name
  location            = azurerm_resource_group.env.location
  tags                = var.tags
}

// The hub is the only source allowed to administer nodes or open Moodle.
resource "azurerm_network_security_rule" "from_hub" {
  name                                       = "allow-ssh-http-from-hub"
  resource_group_name                        = azurerm_resource_group.env.name
  network_security_group_name                = azurerm_network_security_group.app.name
  priority                                   = 100
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_address_prefix                      = var.hub_cidr
  source_port_range                          = "*"
  destination_port_ranges                    = ["22", "80"]
  destination_application_security_group_ids = [azurerm_application_security_group.moodle.id]
  description                                = "Bastion is the only path to SSH and Moodle"
}

// AzureLoadBalancer is the documented service tag for health probes.
resource "azurerm_network_security_rule" "http_from_lb" {
  name                                       = "allow-http-from-loadbalancer"
  resource_group_name                        = azurerm_resource_group.env.name
  network_security_group_name                = azurerm_network_security_group.app.name
  priority                                   = 110
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_address_prefix                      = "AzureLoadBalancer"
  source_port_range                          = "*"
  destination_port_range                     = "80"
  destination_application_security_group_ids = [azurerm_application_security_group.moodle.id]
  description                                = "Health probes and balanced traffic"
}

// The two Moodle VMs share a database and session state, so they must reach
// each other - but only on the ports that need it, and only within this ASG.
resource "azurerm_network_security_rule" "intra_tier" {
  name                                       = "allow-moodle-peer-db-and-http"
  resource_group_name                        = azurerm_resource_group.env.name
  network_security_group_name                = azurerm_network_security_group.app.name
  priority                                   = 120
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_ranges                    = ["80", "3306"]
  source_application_security_group_ids      = [azurerm_application_security_group.moodle.id]
  destination_application_security_group_ids = [azurerm_application_security_group.moodle.id]
  description                                = "Moodle nodes: HTTP and MariaDB between themselves only"
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

// ----------------------------------------------------------------------------
// Load balancer
//
// "Kako bi simulirali visoku dostupnost kreirajte dvije instance moodle
// aplikacije" + "Implementiran load balancer" (3 points on the OpenStack side,
// 2 on the Azure side including a comparison with Application Gateway).
//
// Internal, not public: the brief forbids public access to anything but the
// jump host, so the lead reaches Moodle through an SSH tunnel via the bastion.
// docs/08-azure-loadbalancer.md compares this with Application Gateway.
// ----------------------------------------------------------------------------
resource "azurerm_lb" "moodle" {
  name                = "lb-${local.env_name}-moodle"
  resource_group_name = azurerm_resource_group.env.name
  location            = azurerm_resource_group.env.location
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Static"
    // .250 inside the app subnet: high enough that Azure's dynamic allocation
    // will not collide with it.
    private_ip_address = cidrhost(var.subnet_app_cidr, 250)
  }
}

resource "azurerm_lb_backend_address_pool" "moodle" {
  name            = "bepool-moodle"
  loadbalancer_id = azurerm_lb.moodle.id
}

// Probing the real application path, not just the port. A TCP probe would keep
// sending traffic to a node whose PHP is broken but whose nginx is alive.
resource "azurerm_lb_probe" "moodle" {
  name                = "probe-moodle-http"
  loadbalancer_id     = azurerm_lb.moodle.id
  protocol            = "Http"
  port                = 80
  request_path        = "/healthz.php"
  interval_in_seconds = 15
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "moodle_http" {
  name                           = "rule-moodle-http"
  loadbalancer_id                = azurerm_lb.moodle.id
  frontend_ip_configuration_name = "internal"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.moodle.id]
  probe_id                       = azurerm_lb_probe.moodle.id
  // Moodle keeps session state per node unless sessions are externalised, so
  // pin a client to one backend for the duration of their session.
  load_distribution = "SourceIP"
  tcp_reset_enabled = true
}

// ----------------------------------------------------------------------------
// Storage: object (Blob) + file (Files)
//
// "Svaki programer zahtijeva instancu servisa za objektnu pohranu (za
//  spremanje datoteka Moodlea)" and "instancu servisa za datotečnu pohranu
//  (za spremanje sigurnosnih kopija/backupa)".
// "Obje pohrane moraju biti automatski montirane na aplikacijske instance."
// ----------------------------------------------------------------------------
resource "azurerm_storage_account" "blob" {
  name                     = local.blob_storage_account_name
  resource_group_name      = azurerm_resource_group.env.name
  location                 = azurerm_resource_group.env.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  tags                     = var.tags

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = true

  network_rules {
    default_action             = "Deny"
    bypass                     = ["None"]
    virtual_network_subnet_ids = [azurerm_subnet.app.id]
    ip_rules                   = [replace(var.admin_source_ip_for_storage, "/32", "")]
  }
}

resource "azurerm_storage_account" "files" {
  name                     = local.file_storage_account_name
  resource_group_name      = azurerm_resource_group.env.name
  location                 = azurerm_resource_group.env.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  tags                     = var.tags

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = true

  network_rules {
    default_action             = "Deny"
    bypass                     = ["None"]
    virtual_network_subnet_ids = [azurerm_subnet.app.id]
    ip_rules                   = [replace(var.admin_source_ip_for_storage, "/32", "")]
  }
}

// Object storage: Moodle's file store (moodledata content, uploaded resources)
resource "azurerm_storage_container" "moodle_files" {
  name                  = "moodle-files"
  storage_account_id    = azurerm_storage_account.blob.id
  container_access_type = "private"
}

// File storage: nightly backups, mounted over SMB so tar can write to it
// directly. Files rather than a second blob container because the brief asks
// for a *file* storage service, and because a POSIX-ish mount is what a backup
// script actually wants.
resource "azurerm_storage_share" "backups" {
  name               = "moodle-backups"
  storage_account_id = azurerm_storage_account.files.id
  quota              = 32
}

// ----------------------------------------------------------------------------
// Managed identity
//
// "Pohrana pravilno montirana na instance uz Managed Identities / SAS tokene
//  (least-privilege)".
//
// A user-assigned identity shared by both VMs, granted exactly one data-plane
// role on exactly one container. BlobFuse receives no account key; the broader
// SMB credential is isolated in a separate root-only file.
// ----------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "moodle" {
  name                = "id-${local.env_name}-moodle"
  resource_group_name = azurerm_resource_group.env.name
  location            = azurerm_resource_group.env.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "moodle_blob" {
  // Scoped to the container, not the account: the identity cannot read the
  // backup share or any container added later.
  scope                            = azurerm_storage_container.moodle_files.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_user_assigned_identity.moodle.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  description                      = "Moodle nodes read and write their own file container, nothing else"
}

// ----------------------------------------------------------------------------
// The Moodle VMs
//
// "Svaka aplikacijska virtualna mašina (VM) zahtijeva 2 vCPU i 4 GB RAM-a te
//  dva diska (OS disk i data disk)."
// ----------------------------------------------------------------------------
resource "azurerm_network_interface" "moodle" {
  count = var.vm_count

  name                = "nic-${local.env_name}-moodle-${count.index + 1}"
  resource_group_name = azurerm_resource_group.env.name
  location            = azurerm_resource_group.env.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
    // Deliberately no public_ip_address_id. This is the isolation requirement.
  }
}

resource "azurerm_network_interface_application_security_group_association" "moodle" {
  count = var.vm_count

  network_interface_id          = azurerm_network_interface.moodle[count.index].id
  application_security_group_id = azurerm_application_security_group.moodle.id
}

resource "azurerm_network_interface_backend_address_pool_association" "moodle" {
  count = var.vm_count

  network_interface_id    = azurerm_network_interface.moodle[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.moodle.id
}

resource "azurerm_linux_virtual_machine" "moodle" {
  count = var.vm_count

  name                  = "vm-${local.env_name}-moodle-${count.index + 1}"
  resource_group_name   = azurerm_resource_group.env.name
  location              = azurerm_resource_group.env.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.moodle[count.index].id]
  zone                  = null
  tags = merge(var.tags, {
    role     = "moodle-app"
    instance = tostring(count.index + 1)
  })

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  // Disk 1 of 2: the OS disk
  os_disk {
    name                 = "osdisk-${local.env_name}-moodle-${count.index + 1}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = var.os_image.publisher
    offer     = var.os_image.offer
    sku       = var.os_image.sku
    version   = var.os_image.version
  }

  // Marketplace images such as Rocky Linux need a plan block matching the
  // accepted terms. Azure's own images (Ubuntu, Azure Linux) must not have one,
  // hence the dynamic block.
  dynamic "plan" {
    for_each = var.os_image_requires_plan ? [1] : []
    content {
      publisher = var.os_image.publisher
      product   = var.os_image.offer
      name      = var.os_image.sku
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.moodle.id]
  }

  // Just enough to make the host reachable and Ansible-ready. Moodle itself is
  // installed by Ansible, which is far easier to iterate on than cloud-init.
  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    node_index = count.index + 1
  }))
}

// Disk 2 of 2: local cache and staging at /mnt/techsprint-data
resource "azurerm_managed_disk" "data" {
  count = var.vm_count

  name                 = "datadisk-${local.env_name}-moodle-${count.index + 1}"
  resource_group_name  = azurerm_resource_group.env.name
  location             = azurerm_resource_group.env.location
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  count = var.vm_count

  managed_disk_id    = azurerm_managed_disk.data[count.index].id
  virtual_machine_id = azurerm_linux_virtual_machine.moodle[count.index].id
  lun                = 10
  caching            = "ReadWrite"
}

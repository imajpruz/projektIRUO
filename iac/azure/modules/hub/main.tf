// ============================================================================
// Hub: the jump host / bastion and the DevOps Lead VM
//
// "Okruženju se pristupa isključivo kroz 'jump host' (bastion) mašinu. Ne
// smije postojati izravan javni pristup ostalim instancama."
//
// This module owns the only public IP address in the entire Azure deployment.
// Every developer VNet peers to this hub and to nothing else, which gives the
// lead reachability to all environments while leaving developers unable to
// reach each other. That hub-and-spoke shape is what satisfies both the
// isolation requirement and the lead-access requirement at once.
// ============================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

resource "azurerm_resource_group" "hub" {
  name     = "rg-${var.name_prefix}-hub"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-${var.name_prefix}-hub"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "jump" {
  name                 = "snet-jump"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.subnet_cidr]
}

resource "azurerm_network_security_group" "jump" {
  name                = "nsg-${var.name_prefix}-jump"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  tags                = var.tags
}

// The one deliberate opening in the whole deployment, and even this is
// restricted to a single source address rather than the internet.
resource "azurerm_network_security_rule" "jump_ssh_in" {
  name                        = "allow-ssh-from-admin"
  resource_group_name         = azurerm_resource_group.hub.name
  network_security_group_name = azurerm_network_security_group.jump.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = var.admin_source_ip
  source_port_range           = "*"
  destination_port_range      = "22"
  destination_address_prefix  = "*"
  description                 = "SSH to the bastion from the administrator address only"
}

// Forwarded packets are evaluated by the NVA subnet NSG. Permit only
// developer-to-Internet traffic before the explicit inbound deny below; this
// does not expose additional services on the jump host itself.
resource "azurerm_network_security_rule" "spoke_egress_in" {
  for_each = var.developer_cidrs

  name                        = "allow-egress-from-${each.key}"
  resource_group_name         = azurerm_resource_group.hub.name
  network_security_group_name = azurerm_network_security_group.jump.name
  priority                    = 150 + index(sort(keys(var.developer_cidrs)), each.key)
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_address_prefix       = each.value
  source_port_range           = "*"
  destination_address_prefix  = "Internet"
  destination_port_range      = "*"
  description                 = "Forward ${each.key} package-download traffic through the jump NVA"
}

// Explicit deny above Azure's own 65500 default. Redundant by itself, but it
// makes the intent readable in the portal and in the report's NSG screenshot.
resource "azurerm_network_security_rule" "jump_deny_other_in" {
  name                        = "deny-all-other-inbound"
  resource_group_name         = azurerm_resource_group.hub.name
  network_security_group_name = azurerm_network_security_group.jump.name
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = "*"
  destination_port_range      = "*"
  description                 = "Nothing else reaches the bastion"
}

resource "azurerm_network_security_rule" "jump_ssh_out_to_spokes" {
  for_each = var.developer_cidrs

  name                        = "allow-ssh-to-${each.key}"
  resource_group_name         = azurerm_resource_group.hub.name
  network_security_group_name = azurerm_network_security_group.jump.name
  priority                    = 200 + index(sort(keys(var.developer_cidrs)), each.key)
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = each.value
  destination_port_range      = "22"
  description                 = "Bastion SSH into ${each.key}'s environment"
}

resource "azurerm_network_security_rule" "jump_http_out_to_spokes" {
  for_each = var.developer_cidrs

  name                        = "allow-http-to-${each.key}"
  resource_group_name         = azurerm_resource_group.hub.name
  network_security_group_name = azurerm_network_security_group.jump.name
  priority                    = 300 + index(sort(keys(var.developer_cidrs)), each.key)
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = each.value
  destination_port_range      = "80"
  description                 = "Bastion reaches ${each.key}'s private Moodle load balancer"
}

resource "azurerm_network_security_rule" "jump_deny_other_spoke_out" {
  name                        = "deny-other-private-outbound"
  resource_group_name         = azurerm_resource_group.hub.name
  network_security_group_name = azurerm_network_security_group.jump.name
  priority                    = 3000
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = "10.0.0.0/8"
  destination_port_range      = "*"
  description                 = "Only SSH and HTTP may enter developer networks"
}

resource "azurerm_subnet_network_security_group_association" "jump" {
  subnet_id                 = azurerm_subnet.jump.id
  network_security_group_id = azurerm_network_security_group.jump.id
}

// ----------------------------------------------------------------------------
// The jump host / lead VM
// ----------------------------------------------------------------------------
resource "azurerm_public_ip" "jump" {
  name                = "pip-${var.name_prefix}-jump"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "jump" {
  name                  = "nic-${var.name_prefix}-jump"
  resource_group_name   = azurerm_resource_group.hub.name
  location              = azurerm_resource_group.hub.location
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.jump.id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(var.subnet_cidr, 4)
    public_ip_address_id          = azurerm_public_ip.jump.id
  }
}

resource "azurerm_linux_virtual_machine" "jump" {
  name                  = "vm-${var.name_prefix}-jump"
  resource_group_name   = azurerm_resource_group.hub.name
  location              = azurerm_resource_group.hub.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.jump.id]
  tags                  = merge(var.tags, { role = "jump-host" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "osdisk-${var.name_prefix}-jump"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 32
  }

  // Ubuntu for the bastion on purpose: it needs no marketplace terms
  // acceptance, so a fresh subscription can run the deployment unattended.
  // The Moodle VMs use Rocky Linux, as the brief requires.
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  // The lead's private key is placed here by Ansible, not by cloud-init, so it
  // never appears in VM metadata that any reader of the subscription can fetch.
  custom_data = base64encode(<<-CLOUDINIT
    #cloud-config
    package_update: true
    packages:
      - tmux
      - jq
      - python3
      - nftables
    write_files:
      - path: /etc/ssh/sshd_config.d/60-techsprint.conf
        permissions: "0644"
        content: |
          PasswordAuthentication no
          PermitRootLogin no
          AllowAgentForwarding yes
      - path: /etc/sysctl.d/99-techsprint-forwarding.conf
        permissions: "0644"
        content: |
          net.ipv4.ip_forward=1
      - path: /etc/nftables.conf
        permissions: "0644"
        content: |
          table ip techsprint_filter {
            chain forward {
              type filter hook forward priority filter; policy drop;
              ct state established,related accept
              ip saddr 10.0.0.0/8 ip daddr 10.0.0.0/8 drop
              ip saddr 10.0.0.0/8 ip daddr 172.16.0.0/12 drop
              ip saddr 10.0.0.0/8 ip daddr 192.168.0.0/16 drop
              ip saddr 10.0.0.0/8 accept
            }
          }
          table ip techsprint_nat {
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              ip saddr 10.0.0.0/8 oifname "eth0" masquerade
            }
          }
    runcmd:
      - [ sysctl, --system ]
      - [ systemctl, enable, --now, nftables ]
      - [ systemctl, restart, ssh ]
      - [ touch, /var/lib/techsprint-nva-ready ]
      - [ bash, -c, "echo 'TECHSPRINT-JUMP-READY' > /etc/motd" ]
    CLOUDINIT
  )
}

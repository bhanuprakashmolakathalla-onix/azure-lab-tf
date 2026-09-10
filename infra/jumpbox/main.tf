# The jumpbox: the only way in.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS AT ALL
#
# public_network_access_enabled = false on the workspace means the Databricks
# UI, CLI, REST API and Terraform provider are unreachable from your laptop.
# Not "slow", not "needs a token" - the hostname resolves to a private address
# your laptop has no route to. Something inside the network has to act on your
# behalf, and that something is this VM.
#
# GCP DELTA: there is no IAP TCP forwarding here. GCP lets you reach a
# no-external-IP VM through an identity-aware proxy with no bastion host and no
# public address anywhere. Azure's equivalent is Azure Bastion - a managed
# service, ~Rs 12/hour for the Basic SKU, billed whether or not you connect.
# For a lab that lives one day, a small VM with an IP-locked NSG costs a third
# of that. In production you would use Bastion and this VM would have no public
# IP at all.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "network" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "network.tfstate"
    use_azuread_auth     = true
  }
}

locals {
  net = data.terraform_remote_state.network.outputs
  rg  = local.net.transit_resource_group

  # Derive the location from the subnet rather than hardcoding it - a jumpbox
  # in a different region to its own subnet is not a thing Azure will build.
  location = "centralindia"
}

# --- The NSG, which is the actual security control -------------------------
#
# One allow rule. Everything else falls through to Azure's default
# DenyAllInBound at priority 65500, which is why there is no explicit deny here:
# adding one at a low priority would also shadow AllowVnetInBound (65000) and
# AllowAzureLoadBalancerInBound (65001), and break the machine in ways that look
# like a networking fault rather than a rule you wrote.
resource "azurerm_network_security_group" "jumpbox" {
  name                = "nsg-jumpbox"
  resource_group_name = local.rg
  location            = local.location
  tags                = var.tags

  security_rule {
    name                       = "AllowRdpFromMe"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "${var.allowed_source_ip}/32"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "jumpbox" {
  subnet_id                 = local.net.jumpbox_subnet_id
  network_security_group_id = azurerm_network_security_group.jumpbox.id
}

# --- The machine -----------------------------------------------------------

resource "azurerm_public_ip" "jumpbox" {
  name                = "pip-jumpbox"
  resource_group_name = local.rg
  location            = local.location
  allocation_method   = "Static"
  sku                 = "Standard" # Basic is retired; Standard is deny-by-default inbound
  tags                = var.tags
}

resource "azurerm_network_interface" "jumpbox" {
  name                = "nic-jumpbox"
  resource_group_name = local.rg
  location            = local.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.net.jumpbox_subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox.id
  }
}

resource "azurerm_windows_virtual_machine" "jumpbox" {
  name                = "vm-jumpbox"
  resource_group_name = local.rg
  location            = local.location
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.jumpbox.id]

  # Trusted launch: secure boot + virtual TPM. Costs nothing, blocks bootkits,
  # and is required for several Defender features. There is no reason to skip it.
  secure_boot_enabled = true
  vtpm_enabled        = true

  # Premium, not StandardSSD. Ebsv5 is the PREMIUM-STORAGE-OPTIMIZED family -
  # its entire reason to exist is high remote-disk throughput, and pairing it
  # with a StandardSSD disk throttles the machine to ~500 IOPS with Standard
  # latency. On a B2s the cheap disk was correct; here it made the VM crawl.
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition" # the gen2 SKU trusted launch needs
    version   = "latest"
  }

  # Deallocated VMs bill only for the disk. A jumpbox left running overnight is
  # the classic lab cost leak - this closes it whether or not you remember.
  lifecycle {
    ignore_changes = [admin_password]
  }
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "jumpbox" {
  virtual_machine_id = azurerm_windows_virtual_machine.jumpbox.id
  location           = local.location
  enabled            = true

  daily_recurrence_time = "2300"
  timezone              = "India Standard Time"

  notification_settings {
    enabled = false
  }
}

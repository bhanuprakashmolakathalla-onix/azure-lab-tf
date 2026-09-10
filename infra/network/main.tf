# Private network foundation. Nothing in the data tier gets a public path.
#
# ---------------------------------------------------------------------------
#   transit VNet    you / jumpbox  -> FRONT-END endpoint -> Databricks control plane
#   workspace VNet  cluster nodes  -> BACK-END  endpoint -> Databricks control plane
#                                  -> storage endpoints  -> ADLS
#
# Both Databricks endpoints target the same sub-resource and therefore the same
# hostname, but a user and a cluster must resolve it to different private IPs.
# One zone cannot hold two A records for one name, and two same-named zones
# cannot share a resource group - hence two of each.
#
# GCP comparison: this is the Private Service Connect front-end/back-end split.
# The difference is that Azure makes you own the DNS explicitly where Google
# largely hides it behind Private Google Access.
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "transit" {
  name     = var.transit_resource_group
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "workspace" {
  name     = var.workspace_resource_group
  location = var.location
  tags     = var.tags
}

# --- Transit VNet: humans and the app -------------------------------------

resource "azurerm_virtual_network" "transit" {
  name                = "vnet-transit"
  resource_group_name = azurerm_resource_group.transit.name
  location            = azurerm_resource_group.transit.location
  address_space       = [var.transit_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "transit_privatelink" {
  name                 = "snet-privatelink"
  resource_group_name  = azurerm_resource_group.transit.name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [cidrsubnet(var.transit_address_space, 8, 1)] # 10.10.1.0/24

  # Private endpoints cannot coexist with subnet network policies.
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "jumpbox" {
  name                 = "snet-jumpbox"
  resource_group_name  = azurerm_resource_group.transit.name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [cidrsubnet(var.transit_address_space, 8, 2)] # 10.10.2.0/24
}

# Container Apps needs its own delegated subnet for VNet integration, and it
# wants a LARGE one: /23 minimum for a workload-profile environment. The app is
# the only thing here that faces the public internet, and it reaches Databricks
# over the peering rather than over the internet.
resource "azurerm_subnet" "apps" {
  name                 = "snet-apps"
  resource_group_name  = azurerm_resource_group.transit.name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [cidrsubnet(var.transit_address_space, 7, 2)] # 10.10.4.0/23

  delegation {
    name = "containerapps"
    service_delegation {
      name = "Microsoft.App/environments"
    }
  }
}

# --- Workspace VNet: clusters ---------------------------------------------

resource "azurerm_virtual_network" "workspace" {
  name                = "vnet-databricks"
  resource_group_name = azurerm_resource_group.workspace.name
  location            = azurerm_resource_group.workspace.location
  address_space       = [var.workspace_address_space]
  tags                = var.tags
}

# THE TWO DELEGATED SUBNETS.
#
# Databricks calls them public and private, which misleads under secure cluster
# connectivity: neither gets a public IP. They are host (driver/executor
# interfaces) and container (the container network), and every node consumes one
# address in EACH - so a /24 pair supports roughly 125 nodes, not 250.
#
# Delegation cannot be added to a subnet that already contains anything, and the
# size cannot be changed afterwards. Both are one-way decisions.
locals {
  databricks_delegation_actions = [
    "Microsoft.Network/virtualNetworks/subnets/join/action",
    "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
    "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
  ]
}

resource "azurerm_subnet" "host" {
  name                 = "snet-host"
  resource_group_name  = azurerm_resource_group.workspace.name
  virtual_network_name = azurerm_virtual_network.workspace.name
  address_prefixes     = [cidrsubnet(var.workspace_address_space, 8, 1)] # 10.20.1.0/24

  delegation {
    name = "databricks"
    service_delegation {
      name    = "Microsoft.Databricks/workspaces"
      actions = local.databricks_delegation_actions
    }
  }
}

resource "azurerm_subnet" "container" {
  name                 = "snet-container"
  resource_group_name  = azurerm_resource_group.workspace.name
  virtual_network_name = azurerm_virtual_network.workspace.name
  address_prefixes     = [cidrsubnet(var.workspace_address_space, 8, 2)] # 10.20.2.0/24

  delegation {
    name = "databricks"
    service_delegation {
      name    = "Microsoft.Databricks/workspaces"
      actions = local.databricks_delegation_actions
    }
  }
}

# Back-end and storage private endpoints. Deliberately NOT delegated - a
# delegated subnet cannot host private endpoints.
resource "azurerm_subnet" "workspace_privatelink" {
  name                 = "snet-privatelink"
  resource_group_name  = azurerm_resource_group.workspace.name
  virtual_network_name = azurerm_virtual_network.workspace.name
  address_prefixes     = [cidrsubnet(var.workspace_address_space, 8, 3)] # 10.20.3.0/24

  private_endpoint_network_policies = "Disabled"
}

# --- NSG ------------------------------------------------------------------
#
# Azure requires an NSG on both delegated subnets. With back-end Private Link we
# tell Databricks not to inject its own rules
# (network_security_group_rules_required = "NoAzureDatabricksRules" on the
# workspace), because control-plane traffic no longer crosses the internet and
# those rules would permit paths that should not exist.
#
# No rules of our own: the NSG default already allows intra-VNet and outbound
# and denies inbound from the internet. Adding permissive rules here would
# quietly undo the isolation this whole module exists to create.
resource "azurerm_network_security_group" "databricks" {
  name                = "nsg-databricks"
  resource_group_name = azurerm_resource_group.workspace.name
  location            = azurerm_resource_group.workspace.location
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "host" {
  subnet_id                 = azurerm_subnet.host.id
  network_security_group_id = azurerm_network_security_group.databricks.id
}

resource "azurerm_subnet_network_security_group_association" "container" {
  subnet_id                 = azurerm_subnet.container.id
  network_security_group_id = azurerm_network_security_group.databricks.id
}

# --- Egress ---------------------------------------------------------------
#
# Nodes have no public IP and private endpoints cover only the Databricks
# control plane and storage. Clusters still need outbound for runtime artifacts
# and package installs. Without a path they hang at startup and fail in a way
# that looks like slowness rather than a network problem.
#
# NAT gateway over Azure Firewall: outbound only, no inbound path, no rules to
# maintain, ~Rs 100/day against Rs 1,000+. Firewall earns its cost when you need
# FQDN filtering and egress logging - the natural next step in a regulated
# environment, and the reason this is a variable rather than a permanent choice.
resource "azurerm_public_ip" "nat" {
  name                = "pip-nat-databricks"
  resource_group_name = azurerm_resource_group.workspace.name
  location            = azurerm_resource_group.workspace.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "databricks" {
  name                    = "nat-databricks"
  resource_group_name     = azurerm_resource_group.workspace.name
  location                = azurerm_resource_group.workspace.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "nat" {
  nat_gateway_id       = azurerm_nat_gateway.databricks.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

# Both delegated subnets egress through one address, which is what makes
# allowlisting on the far side possible at all.
resource "azurerm_subnet_nat_gateway_association" "host" {
  subnet_id      = azurerm_subnet.host.id
  nat_gateway_id = azurerm_nat_gateway.databricks.id
}

resource "azurerm_subnet_nat_gateway_association" "container" {
  subnet_id      = azurerm_subnet.container.id
  nat_gateway_id = azurerm_nat_gateway.databricks.id
}

# --- Private DNS: Databricks ----------------------------------------------
#
# The two same-named zones. Each links to exactly ONE VNet, so a lookup of the
# workspace hostname resolves to the endpoint appropriate to where it came from.
# No auto-registration - these hold private endpoint records only.

resource "azurerm_private_dns_zone" "databricks_frontend" {
  name                = "privatelink.azuredatabricks.net"
  resource_group_name = azurerm_resource_group.transit.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "frontend" {
  name                  = "link-transit"
  resource_group_name   = azurerm_resource_group.transit.name
  private_dns_zone_name = azurerm_private_dns_zone.databricks_frontend.name
  virtual_network_id    = azurerm_virtual_network.transit.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone" "databricks_backend" {
  name                = "privatelink.azuredatabricks.net"
  resource_group_name = azurerm_resource_group.workspace.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "backend" {
  name                  = "link-workspace"
  resource_group_name   = azurerm_resource_group.workspace.name
  private_dns_zone_name = azurerm_private_dns_zone.databricks_backend.name
  virtual_network_id    = azurerm_virtual_network.workspace.id
  registration_enabled  = false
  tags                  = var.tags
}

# --- Private DNS: storage -------------------------------------------------
#
# ADLS Gen2 needs BOTH zones: dfs for the Data Lake API that Spark and Unity
# Catalog use, blob for the legacy API several tools still reach for. Cover only
# dfs and something eventually fails resolving blob, with an error that says
# nothing about DNS.
#
# Unlike the Databricks zones these link to BOTH VNets - storage resolves to the
# same address from everywhere, so there is no split to model.
resource "azurerm_private_dns_zone" "dfs" {
  name                = "privatelink.dfs.core.windows.net"
  resource_group_name = azurerm_resource_group.workspace.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.workspace.name
  tags                = var.tags
}

locals {
  storage_zone_links = {
    "dfs-transit"    = { zone = azurerm_private_dns_zone.dfs.name, vnet = azurerm_virtual_network.transit.id }
    "dfs-workspace"  = { zone = azurerm_private_dns_zone.dfs.name, vnet = azurerm_virtual_network.workspace.id }
    "blob-transit"   = { zone = azurerm_private_dns_zone.blob.name, vnet = azurerm_virtual_network.transit.id }
    "blob-workspace" = { zone = azurerm_private_dns_zone.blob.name, vnet = azurerm_virtual_network.workspace.id }
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage" {
  for_each = local.storage_zone_links

  name                  = "link-${each.key}"
  resource_group_name   = azurerm_resource_group.workspace.name
  private_dns_zone_name = each.value.zone
  virtual_network_id    = each.value.vnet
  registration_enabled  = false
  tags                  = var.tags
}

# --- Peering --------------------------------------------------------------
#
# The app and the jumpbox sit in transit and must reach storage endpoints in the
# workspace VNet. Peering is non-transitive and must be declared from BOTH
# sides - a one-sided peering sits at "Initiated" forever and passes no traffic,
# which is a classic afternoon lost to staring at NSGs.
resource "azurerm_virtual_network_peering" "transit_to_workspace" {
  name                         = "peer-transit-to-workspace"
  resource_group_name          = azurerm_resource_group.transit.name
  virtual_network_name         = azurerm_virtual_network.transit.name
  remote_virtual_network_id    = azurerm_virtual_network.workspace.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

resource "azurerm_virtual_network_peering" "workspace_to_transit" {
  name                         = "peer-workspace-to-transit"
  resource_group_name          = azurerm_resource_group.workspace.name
  virtual_network_name         = azurerm_virtual_network.workspace.name
  remote_virtual_network_id    = azurerm_virtual_network.transit.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

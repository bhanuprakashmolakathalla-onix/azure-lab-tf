# The lake, with no public path to it.
#
# ---------------------------------------------------------------------------
# THE DISTINCTION THAT MATTERS: two ways to close a storage account, and only
# one of them leaves Unity Catalog working.
#
#   public_network_access_enabled = false
#       Kills the public endpoint outright. Firewall rules and resource-instance
#       exceptions stop applying, because there is no longer anything public to
#       make an exception on. Maximum closure - and it BREAKS Unity Catalog:
#       credential and external-location validation runs from the Databricks
#       CONTROL PLANE, which is outside your VNet. You get a storage credential
#       that cannot be validated and external locations that refuse to create.
#
#   network_rules { default_action = "Deny", private_link_access = [connector] }
#       The public endpoint exists but denies everything, EXCEPT the named
#       resource instance - here the Access Connector - which reaches storage
#       over Microsoft's backbone rather than the internet.
#
# The second is what production actually runs. "No public access" is true of
# both; only one of them also works.
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
}

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# --- ADLS Gen2 ------------------------------------------------------------

resource "azurerm_storage_account" "lake" {
  name                = var.storage_account_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # Hierarchical namespace: real directories with atomic rename, which is what
  # makes a Delta commit safe. Cannot be toggled after creation.
  is_hns_enabled = true

  # No account keys at all. Everything authenticates with an Entra identity.
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # THE FIREWALL. Deny by default; the Access Connector is the one exception,
  # and it reaches storage over the Microsoft backbone rather than the internet.
  #
  # bypass = AzureServices is required for the platform operations that keep
  # storage working at all (metrics, diagnostics). It does NOT open a data path
  # for arbitrary callers.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]

    private_link_access {
      endpoint_resource_id = azurerm_databricks_access_connector.uc.id
    }
  }

  blob_properties {
    # NOTE: versioning_enabled is absent deliberately - Azure rejects blob
    # versioning on HNS accounts. Delta's transaction log is the replacement,
    # and it versions per TABLE rather than per blob, which is what you want.
    delete_retention_policy {
      days = 7
    }
  }

  tags = var.tags
}

# Containers are created through ARM (control plane), not the blob data plane -
# note `storage_account_id` rather than the deprecated `storage_account_name`.
#
# That distinction is what lets this apply keep working from a laptop after the
# firewall closes: ARM is not subject to the storage firewall. Had we used the
# name-based form, container creation would now fail from outside the VNet.
resource "azurerm_storage_container" "layers" {
  for_each = toset(var.containers)

  name               = each.value
  storage_account_id = azurerm_storage_account.lake.id
}

# --- Private endpoints ----------------------------------------------------
#
# BOTH dfs and blob. dfs is the Data Lake API that Spark and Unity Catalog speak;
# blob is the legacy API several tools still reach for. Cover only dfs and
# something eventually fails resolving the blob endpoint, with an error that
# says nothing about DNS.
#
# private_dns_zone_group is what writes the A record into the zone. Without it
# the endpoint exists, holds an IP, and nothing resolves to it - the single most
# common private-endpoint mistake.
locals {
  storage_endpoints = {
    dfs  = local.net.dns_zone_ids.dfs
    blob = local.net.dns_zone_ids.blob
  }
}

resource "azurerm_private_endpoint" "storage" {
  for_each = local.storage_endpoints

  name                = "pe-${var.storage_account_name}-${each.key}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  subnet_id           = local.net.workspace_privatelink_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = azurerm_storage_account.lake.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-${each.key}"
    private_dns_zone_ids = [each.value]
  }
}

# --- Access Connector -----------------------------------------------------
#
# The managed identity Unity Catalog assumes to reach the lake. No credential
# ever materialises - Azure brokers the token internally. It is also the
# resource instance named in the storage firewall above, which is what lets UC
# validate credentials against a closed account.
resource "azurerm_databricks_access_connector" "uc" {
  name                = "dbac-lab01-uc"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# --- Data-plane RBAC ------------------------------------------------------
#
# Creating the connector grants it nothing: Azure splits `actions` (manage the
# resource) from `dataActions` (touch the data inside), and Owner-style control
# plane roles carry `dataActions: []`.
#
# Contributor rather than Owner: the Owner variant additionally grants POSIX ACL
# management, which UC does not need and which would let a compromised metastore
# rewrite permissions on the lake.
resource "azurerm_role_assignment" "uc_on_lake" {
  scope                            = azurerm_storage_account.lake.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_databricks_access_connector.uc.identity[0].principal_id
  skip_service_principal_aad_check = true
}

# Human and machine access to the lake, PINNED.
#
# This deliberately does not use data.azurerm_client_config.current - "whoever is
# running Terraform" resolves differently locally and in CI, and principal_id is
# ForceNew, so alternating runs would destroy and recreate the assignment and
# silently revoke whoever ran last.
resource "azurerm_role_assignment" "lake_data_admins" {
  for_each = var.lake_data_admins

  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value.object_id

  # Only meaningful for service principals, and actively wrong for users: the
  # provider turns this into principalType=ServicePrincipal on the request and
  # Azure 400s when the object is a User.
  skip_service_principal_aad_check = each.value.type == "ServicePrincipal"
}

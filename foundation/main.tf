# The foundation: resource group, ADLS Gen2 lake, and the managed identity that
# Unity Catalog will later use to reach it. Everything Day 1 built by hand.

# Who am I? Used below to grant yourself data-plane access to the lake, the same
# way bootstrap-backend.ps1 did for the state account.
data "azurerm_client_config" "current" {}

# --- Resource group -------------------------------------------------------
#
# Reminder on the false friend: this is NOT a GCP project. It is a lifecycle and
# tagging boundary only. It is not a billing boundary, not a quota boundary, and
# not an isolation boundary - the SUBSCRIPTION is all three. What it does give
# you that GCP has no equivalent for is `delete the group, delete everything in
# it`, which is why the whole lab lives in one.
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
  account_replication_type = "LRS" # cheapest; a lab does not need geo-redundancy
  account_kind             = "StorageV2"

  # THE flag that makes this a data lake rather than object storage.
  #
  # Hierarchical namespace gives you real directories with atomic rename, which
  # is what makes Spark writes and Delta commits safe. Without it every "rename"
  # is copy-then-delete, which is slow and non-atomic - the classic S3/GCS
  # eventual-consistency footgun that ADLS Gen2 exists to remove.
  #
  # It cannot be toggled after creation. Getting this wrong means rebuilding.
  is_hns_enabled = true

  # Same posture as the state account: no account keys at all. The Access
  # Connector below authenticates with its managed identity, and you authenticate
  # with your Entra token. Nothing in this repo is a secret.
  shared_access_key_enabled = false

  # With shared keys disabled, the portal still defaults its storage browser to
  # "Access key" auth and greets you with an error. This flips the default to
  # your Entra identity, which is the only thing that can work here anyway.
  default_to_oauth_authentication = true

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  blob_properties {
    # NOTE: `versioning_enabled` is deliberately absent. Azure does not support
    # blob versioning on hierarchical-namespace accounts - it is HNS or
    # versioning, never both, and the API rejects the combination outright.
    #
    # This costs less than it sounds. Blob versioning is the wrong layer for a
    # lakehouse: Delta Lake keeps its own transaction log, so you get time travel
    # and rollback per TABLE, which is what you actually want. The state account
    # keeps versioning precisely because it is NOT HNS and has no Delta log to
    # fall back on.
    #
    # Soft delete IS supported on HNS, so that stays.
    delete_retention_policy {
      days = 7 # shorter than the state account's 30 - this is reproducible data
    }
  }

  tags = var.tags
}

# --- Containers (filesystems) --------------------------------------------
#
# On an HNS account a "container" IS a filesystem - same object, two names,
# depending on whether you came through the blob or the dfs endpoint. Databricks
# will address these as abfss://<name>@<account>.dfs.core.windows.net/
#
# Note `storage_account_id`, not `storage_account_name`: azurerm 4.x deprecated
# the name-based form in favour of the resource ID.
resource "azurerm_storage_container" "layers" {
  for_each = toset(var.containers)

  name               = each.value
  storage_account_id = azurerm_storage_account.lake.id
}

# --- Access Connector -----------------------------------------------------
#
# This is the piece with no GCP analogue and it is worth slowing down for.
#
# In GCP you would give Databricks a service account and hand it a key, or use
# workload identity federation. Azure's answer is a first-class resource: a
# managed identity that Databricks is allowed to assume, with no credential
# ever materialising. Unity Catalog references this connector by resource ID in
# a storage credential, and Azure brokers the token internally.
#
# Nothing to rotate, nothing to leak.
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
# Day 1's lesson as code. Creating the Access Connector grants it nothing. It
# needs an explicit DATA-plane role on the lake, because Owner-style control
# plane permissions carry `dataActions: []`.
#
# Storage Blob Data CONTRIBUTOR, not Owner: the Owner variant additionally grants
# POSIX ACL management, which Unity Catalog does not need and which would let a
# compromised metastore rewrite permissions on the lake.
resource "azurerm_role_assignment" "uc_on_lake" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.uc.identity[0].principal_id

  # Managed identities are created asynchronously in Entra. Assigning a role to
  # a principal ID that has not replicated yet fails with a
  # PrincipalNotFound that looks like a typo. This tells the provider to retry
  # instead of giving up.
  skip_service_principal_aad_check = true
}

# You, too. Owner lets you create this account but not list a single blob, so
# without this you cannot browse the lake in the portal or with `az storage`.
resource "azurerm_role_assignment" "me_on_lake" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Outputs consumed by the workspace and unity-catalog modules.
#
# Each module is its own ROOT module with its own state file - foundation.tfstate,
# workspace.tfstate, and so on, all in the same container. They read each other
# through a `terraform_remote_state` data source, which is the only reason these
# outputs exist. Nothing here is decorative.
#
# Why split state at all, rather than one big module? Blast radius. A
# `terraform destroy` in the compute module physically cannot reach the lake,
# because the lake is not in that state file. Same argument as separate GCS
# state prefixes per component, and the same tradeoff: you trade a single
# `apply` for the guarantee that a bad day stays contained.

output "resource_group_name" {
  description = "Lab resource group. The workspace module deploys into this."
  value       = azurerm_resource_group.lab.name
}

output "location" {
  description = "Region. Must match for the workspace - a metastore is one-per-region."
  value       = azurerm_resource_group.lab.location
}

output "storage_account_name" {
  description = "ADLS Gen2 account backing the lake."
  value       = azurerm_storage_account.lake.name
}

output "storage_account_id" {
  description = "Full ARM ID. Needed to scope role assignments from other modules."
  value       = azurerm_storage_account.lake.id
}

output "dfs_endpoint" {
  description = "Data Lake (dfs) endpoint. Note this is NOT the blob endpoint - Spark speaks dfs."
  value       = azurerm_storage_account.lake.primary_dfs_endpoint
}

output "access_connector_id" {
  description = "ARM ID of the Access Connector. Unity Catalog's storage credential references this exact string."
  value       = azurerm_databricks_access_connector.uc.id
}

output "access_connector_principal_id" {
  description = "Managed identity object ID, for granting further data-plane roles elsewhere."
  value       = azurerm_databricks_access_connector.uc.identity[0].principal_id
}

# Pre-built abfss:// URLs, one per container.
#
# This is the string format Databricks external locations and Spark reads both
# want, and it is easy to get subtly wrong by hand. Note the shape:
#
#   abfss://<container>@<account>.dfs.core.windows.net/
#
# The container goes BEFORE the @, which trips up anyone used to gs://bucket/path
# or s3://bucket/path. And it must be abfss (TLS), not abfs - the account has
# https_traffic_only_enabled, so plain abfs is refused.
output "container_urls" {
  description = "Map of container name to its abfss:// URL, for UC external locations."
  value = {
    for name in var.containers :
    name => "abfss://${name}@${azurerm_storage_account.lake.name}.dfs.core.windows.net/"
  }
}

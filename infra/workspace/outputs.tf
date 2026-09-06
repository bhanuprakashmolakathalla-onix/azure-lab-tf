# Every output is now a MAP keyed by environment ("dev" / "prod"), not a scalar.
#
# This is the part of a for_each refactor that actually costs you time: the shape
# change ripples into every downstream module. unity-catalog and compute both
# have to say workspace_hosts["dev"] where they used to say workspace_host.
#
# Worth doing deliberately rather than by find-and-replace, because a module that
# silently picks the wrong key still plans cleanly and applies to the wrong place.

output "workspace_hosts" {
  description = "env -> https://adb-....azuredatabricks.net. Feeds the databricks provider's host."
  value       = { for k, w in azurerm_databricks_workspace.this : k => "https://${w.workspace_url}" }
}

output "workspace_resource_ids" {
  description = "env -> ARM ID. Feeds azure_workspace_resource_id, which is how the provider mints a token from your az login."
  value       = { for k, w in azurerm_databricks_workspace.this : k => w.id }
}

output "workspace_ids" {
  description = "env -> numeric Databricks workspace ID. This is the value catalog BINDINGS are expressed in, not the ARM ID."
  value       = { for k, w in azurerm_databricks_workspace.this : k => w.workspace_id }
}

output "managed_resource_group_ids" {
  description = "env -> Databricks-owned RG. Watch these for surprise cost."
  value       = { for k, w in azurerm_databricks_workspace.this : k => w.managed_resource_group_id }
}

output "catalog_name" { value = module.catalog.name }
output "catalog_isolation" { value = module.catalog.isolation_mode }
output "schemas" { value = module.catalog.schemas }

output "external_location_names" {
  value = sort([for e in databricks_external_location.layers : e.name])
}

output "storage_credential_name" { value = databricks_storage_credential.adls.name }

output "bound_workspace_id" {
  description = "The single workspace this ISOLATED catalog is visible from. That is the isolation, in one line."
  value       = local.workspace_id
}

output "platform_admins_group" { value = databricks_group.platform_admins.display_name }

output "name" {
  value = databricks_catalog.this.name
}

output "isolation_mode" {
  value = databricks_catalog.this.isolation_mode
}

output "schemas" {
  value = sort([for s in databricks_schema.layer : "${s.catalog_name}.${s.name}"])
}

output "read_only_workspace_ids" {
  value = [for b in databricks_workspace_binding.read_only : b.workspace_id]
}

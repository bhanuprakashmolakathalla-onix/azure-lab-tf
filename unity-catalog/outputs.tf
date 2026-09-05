output "catalogs" {
  description = "Both catalogs with their isolation posture."
  value = {
    dev  = { name = module.catalog_dev.name, isolation = module.catalog_dev.isolation_mode }
    prod = { name = module.catalog_prod.name, isolation = module.catalog_prod.isolation_mode }
  }
}

output "schemas" {
  value = concat(module.catalog_dev.schemas, module.catalog_prod.schemas)
}

output "external_location_names" {
  value = sort([for e in databricks_external_location.layers : e.name])
}

output "bound_workspace_ids" {
  description = "Which numeric workspace each catalog is bound to. This is the isolation, in one line."
  value = {
    dev  = data.terraform_remote_state.workspace.outputs.workspace_ids["dev"]
    prod = data.terraform_remote_state.workspace.outputs.workspace_ids["prod"]
  }
}

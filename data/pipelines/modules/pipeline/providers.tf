# No provider configuration - the caller passes one in, exactly like
# unity-catalog/modules/catalog. Same reason: Terraform cannot choose a provider
# from a for_each key, so one module call per environment is how you target two
# workspaces from one codebase.
terraform {
  required_providers {
    databricks = {
      source = "databricks/databricks"
    }
  }
}

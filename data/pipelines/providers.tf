terraform {
  required_version = ">= 1.9.0"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.50"
    }
  }
}

provider "databricks" {
  alias                       = "dev"
  host                        = data.terraform_remote_state.workspace.outputs.workspace_hosts["dev"]
  azure_workspace_resource_id = data.terraform_remote_state.workspace.outputs.workspace_resource_ids["dev"]
}

provider "databricks" {
  alias                       = "prod"
  host                        = data.terraform_remote_state.workspace.outputs.workspace_hosts["prod"]
  azure_workspace_resource_id = data.terraform_remote_state.workspace.outputs.workspace_resource_ids["prod"]
}

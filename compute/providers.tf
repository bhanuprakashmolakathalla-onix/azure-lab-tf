# Same two-provider bootstrap as unity-catalog - the databricks provider is
# configured from the workspace module's state, not from a resource in this run.
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
  host                        = data.terraform_remote_state.workspace.outputs.workspace_hosts["dev"]
  azure_workspace_resource_id = data.terraform_remote_state.workspace.outputs.workspace_resource_ids["dev"]
}

# ONE workspace now, so one provider - the dev/prod alias pair is gone.
#
# WHERE THIS RUNS: the host below resolves only inside the transit or workspace
# VNet. This module runs from the jumpbox and nowhere else.
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
  host                        = data.terraform_remote_state.workspace.outputs.workspace_host
  azure_workspace_resource_id = data.terraform_remote_state.workspace.outputs.workspace_resource_id
}

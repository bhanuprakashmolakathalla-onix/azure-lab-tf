# Same two-provider bootstrap as data/catalog - the databricks provider is
# configured from the workspace module's state, not from a resource in this run.
#
# WHERE THIS RUNS: the host below resolves only inside the transit or workspace
# VNet. Like every other databricks-provider module, this one runs from the
# jumpbox and nowhere else.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.50"
    }
  }
}

# SCALARS, not map lookups. The workspace module emitted workspace_hosts["dev"]
# and workspace_resource_ids["dev"] while there were two workspaces; it now
# emits one host and one resource id. A map lookup against a scalar fails at
# PLAN, not at validate - remote state outputs are unknown until then - which is
# why this survived a `terraform validate` for a whole restructure.
provider "databricks" {
  host                        = data.terraform_remote_state.workspace.outputs.workspace_host
  azure_workspace_resource_id = data.terraform_remote_state.workspace.outputs.workspace_resource_id
}

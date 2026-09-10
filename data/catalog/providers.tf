# TWO providers, and the split is the important part.
#
# The first talks to a WORKSPACE. The second talks to the ACCOUNT, which is where
# identity lives once Unity Catalog is on: users, groups and service principals
# are account-level objects that get ASSIGNED into workspaces, never created in
# them. That is the shape people get wrong coming from the pre-UC world, where
# every workspace had its own user list. A workspace-local group is a legacy
# object now, and a grant referencing one will not resolve at the metastore.
#
# WHERE THIS RUNS: the workspace provider's host resolves only inside the transit
# or workspace VNet. This module therefore runs from the jumpbox and nowhere
# else - not from the laptop, not from a GitHub-hosted runner. That is the direct,
# unavoidable cost of public_network_access_enabled = false, and it is why
# regulated shops run self-hosted runners.
#
# Both authenticate from `az login`. No tokens, no secrets, nothing to rotate.

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

provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id

  # Without this the provider uses /common, which resolves an MSA-backed identity
  # to the CONSUMER tenant ('Microsoft Services') where the Databricks app does
  # not exist - AADSTS70011. Exactly the same failure as signing into the account
  # console with the raw gmail address.
  #
  # The workspace provider never hits this because azure_workspace_resource_id
  # carries the tenant inside the ARM path. account_id carries no tenant, so it
  # has to be stated.
  azure_tenant_id = var.azure_tenant_id
}

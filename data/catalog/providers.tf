# TWO aliased databricks providers - one per workspace.
#
# This is a direct consequence of what we are about to build. A catalog with
# isolation_mode = "ISOLATED" is invisible from any workspace it is not bound to,
# and that applies to TERRAFORM exactly as it applies to a human. A provider
# pointed at the dev workspace cannot create a schema inside a prod-bound
# catalog; the API returns "catalog does not exist", which reads like a typo.
#
# So isolation is not only a security control. It changes the shape of the code
# that manages it. Most people discover this the hard way, halfway through an
# apply that half-succeeded.
#
# Both aliases still authenticate from your `az login` - no tokens, no secrets.

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

# A THIRD provider, and a different kind of thing entirely.
#
# The dev/prod aliases talk to a WORKSPACE. This one talks to the ACCOUNT, which
# is where identity lives once Unity Catalog is on: users, groups and service
# principals are account-level objects, assigned INTO workspaces rather than
# created in them.
#
# That is the split people get wrong coming from the pre-UC world, where every
# workspace had its own user list. Now a workspace-local group is a legacy shape
# and grants that reference one will not resolve at the metastore.
#
# Note the host is accounts.azuredatabricks.net, not a workspace URL, and it
# needs account_id instead of azure_workspace_resource_id. Auth is still your
# `az login`.
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id

  # Without this the provider uses /common, which resolves an MSA-backed identity
  # to the CONSUMER tenant ('Microsoft Services') where the Databricks app does
  # not exist - AADSTS70011. Exactly the same failure as signing into the account
  # console with the raw gmail address.
  #
  # The workspace-scoped providers never hit this because
  # azure_workspace_resource_id carries the tenant inside the ARM path.
  # account_id carries no tenant, so it has to be stated.
  azure_tenant_id = var.azure_tenant_id
}

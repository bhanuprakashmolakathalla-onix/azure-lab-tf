terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.50"
    }
    # Only for the bag signing key. Random values live in state, which is why
    # the state account has shared keys disabled and Entra-only access.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
  resource_provider_registrations = "none"
}

# Workspace-scoped: the serving compute, its permissions, and the UC grants.
#
# WHERE THIS RUNS: this host resolves only inside the transit or workspace VNet,
# so this module - unlike every other azurerm module - must run from the jumpbox.
# One databricks provider is enough to pin the whole module to that machine.
provider "databricks" {
  host                        = data.terraform_remote_state.workspace.outputs.workspace_host
  azure_workspace_resource_id = data.terraform_remote_state.workspace.outputs.workspace_resource_id
}

# Account-scoped: registering each managed identity as a Databricks service
# principal, and assigning it into the workspace. Identity is always
# account-level once Unity Catalog is on - the same rule as for humans, applied
# to two robots.
provider "databricks" {
  alias           = "account"
  host            = "https://accounts.azuredatabricks.net"
  account_id      = var.databricks_account_id
  azure_tenant_id = var.azure_tenant_id
}

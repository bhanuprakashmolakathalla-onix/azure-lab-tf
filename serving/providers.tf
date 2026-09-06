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
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
  resource_provider_registrations = "none"
}

# Workspace-scoped: the SQL warehouse, its permissions, and the UC grants.
provider "databricks" {
  alias                       = "dev"
  host                        = data.terraform_remote_state.workspace.outputs.workspace_hosts["dev"]
  azure_workspace_resource_id = data.terraform_remote_state.workspace.outputs.workspace_resource_ids["dev"]
}

# Account-scoped: registering the app's managed identity as a Databricks service
# principal, and assigning it into the workspace. Identity is always account-level
# once Unity Catalog is on - the Day 4 rule, applying to a robot this time.
provider "databricks" {
  alias           = "account"
  host            = "https://accounts.azuredatabricks.net"
  account_id      = var.databricks_account_id
  azure_tenant_id = var.azure_tenant_id
}

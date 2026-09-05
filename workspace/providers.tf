# Note what is NOT here: the `databricks` provider.
#
# You cannot configure it yet. Its `host` argument IS the workspace URL, and the
# workspace does not exist until this module applies. A provider block is
# evaluated during plan, before any resource is created, so referencing
# azurerm_databricks_workspace.this.workspace_url from a provider in this same
# module is a chicken-and-egg Terraform cannot resolve.
#
# That constraint is the entire reason unity-catalog is a separate module rather
# than a few more resources in this one. It is the single most common thing
# people get wrong when Terraforming Databricks.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
  resource_provider_registrations = "none"
}

# Same storage account and container as the foundation module. The ONLY line
# that differs is `key` - that is what makes this a separate state file, and
# therefore a separate blast radius.
#
# bootstrap-backend.ps1 generated foundation/backend.tf; this one is written by
# hand because the bootstrap only ever runs once.
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "sttfstatebhanu7391"
    container_name       = "tfstate"
    key                  = "workspace.tfstate"
    use_azuread_auth     = true
  }
}

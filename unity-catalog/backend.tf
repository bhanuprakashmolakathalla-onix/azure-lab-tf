terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "sttfstatebhanu7391"
    container_name       = "tfstate"
    key                  = "unity-catalog.tfstate"
    use_azuread_auth     = true
  }
}

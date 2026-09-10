data "terraform_remote_state" "workspace" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "workspace.tfstate"
    use_azuread_auth     = true
  }
}

# Auto Loader needs real abfss:// paths for the landing zone and its checkpoints.
# Those come from the foundation module's container_urls output, so the storage
# account name is never typed here - rename the account and this follows.
data "terraform_remote_state" "foundation" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "foundation.tfstate"
    use_azuread_auth     = true
  }
}

# One pipeline now. The earlier build instantiated this module twice, once per
# workspace, to make the point that provider selection is STRUCTURAL - a variable
# may change what a resource looks like, never which provider manages it. That
# lesson still holds; there is simply one workspace to point at.
#
# NOTE the checkpoints URL is a separate container, not a folder inside bronze.
# Auto Loader state is operational state, not data: it has a different lifecycle
# from every table, and a `DROP TABLE` must not be able to orphan it. Putting it
# under a medallion layer is a mistake that only shows up the day someone cleans
# up a layer and the next run silently re-ingests everything.
module "pipeline" {
  source = "./modules/pipeline"

  catalog           = var.catalog
  ci_application_id = var.ci_application_id
  landing_url       = data.terraform_remote_state.foundation.outputs.container_urls["landing"]
  checkpoints_url   = data.terraform_remote_state.foundation.outputs.container_urls["checkpoints"]
  start_date        = var.start_date
  num_days          = var.num_days
}

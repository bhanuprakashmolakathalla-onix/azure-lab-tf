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

# Both environments are deployed from ONE state file, each through its own
# provider. This replaces the earlier `-var target_env=prod` approach, which was
# wrong in a way worth remembering:
#
# A single state file records which workspace each object lives in. Flipping a
# variable repointed the provider at prod while state still described dev
# objects, and the provider refused with a workspace_id mismatch. It was right to.
#
# The general rule: a variable may change what a resource LOOKS like, never which
# PROVIDER manages it. Provider selection is structural, so it belongs in module
# instantiation. The alternatives are separate state files per environment
# (via -backend-config at init) or terraform workspaces; module-per-environment
# is the one that keeps a single plan showing both.
module "pipeline_dev" {
  source = "./modules/pipeline"

  providers = {
    databricks = databricks.dev
  }

  env               = "dev"
  ci_application_id = var.ci_application_id
  landing_url       = data.terraform_remote_state.foundation.outputs.container_urls["landing"]
  checkpoints_url   = data.terraform_remote_state.foundation.outputs.container_urls["checkpoints"]
  seed_batch        = var.seed_batch
}

module "pipeline_prod" {
  source = "./modules/pipeline"

  providers = {
    databricks = databricks.prod
  }

  env               = "prod"
  ci_application_id = var.ci_application_id
  landing_url       = data.terraform_remote_state.foundation.outputs.container_urls["landing"]
  checkpoints_url   = data.terraform_remote_state.foundation.outputs.container_urls["checkpoints"]
  seed_batch        = var.seed_batch
}

# `moved` blocks: refactor without destroying.
#
# The dev notebooks and job already exist and are recorded in state at their old
# top-level addresses. Extracting them into a module changes the ADDRESS, and
# without these Terraform would read that as "delete four things, create four
# new ones" - losing the job id, its run history, and anything referencing it.
#
# These tell Terraform the objects simply moved. No API calls, pure state
# surgery, and safe to delete once applied.
moved {
  from = databricks_notebook.layer
  to   = module.pipeline_dev.databricks_notebook.layer
}

moved {
  from = databricks_job.medallion
  to   = module.pipeline_dev.databricks_job.medallion
}

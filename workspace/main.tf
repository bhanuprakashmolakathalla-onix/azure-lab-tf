# Reach into the foundation module's state to find where to deploy.
#
# This is a READ of another module's outputs, not a dependency Terraform can
# order for you. If foundation has never been applied, this data source fails at
# plan time with a confusing "key does not exist" - the fix is always "apply
# foundation first", never "change this block".
#
# GCP comparison: identical to a terraform_remote_state on a GCS prefix. The one
# Azure-specific line is use_azuread_auth - without it the data source tries to
# read the state blob with a shared key, and the state account does not have any.
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

locals {
  foundation = data.terraform_remote_state.foundation.outputs

  tags = {
    purpose    = "databricks-lab"
    owner      = "bhanu"
    autodelete = "true"
  }
}

# for_each rather than count. With count, removing "dev" from the map would
# renumber the list and Terraform would propose DESTROYING prod to recreate it
# at a new index. Keyed resources are stable under insertion and deletion, which
# is why for_each is the right default for anything you might add to later.
resource "azurerm_databricks_workspace" "this" {
  for_each = var.workspace_names

  name                = each.value
  resource_group_name = local.foundation.resource_group_name
  location            = local.foundation.location
  sku                 = var.sku

  # Name the managed resource group explicitly instead of letting Databricks
  # append a random suffix.
  #
  # This RG is created and OWNED by Databricks. It holds the workspace's VNet,
  # NSG, managed storage account, and - if SCC is on - the NAT gateway. It is
  # deny-locked: you cannot add to it, retag it, or delete anything inside it.
  # It disappears only when the workspace does.
  #
  # This is why Day 1's teardown showed the managed RG releasing FIRST and the
  # parent second. Naming it predictably means a teardown script can assert on
  # it rather than pattern-matching a random string.
  managed_resource_group_name = "databricks-rg-${each.value}"

  custom_parameters {
    # THE cost decision in this repo, and the flag with the most misleading name.
    #
    # no_public_ip = true  -> Secure Cluster Connectivity. Cluster nodes get no
    #                         public IP; outbound goes through a NAT GATEWAY that
    #                         Azure bills at roughly Rs 100/DAY, running or idle.
    #                         This is what quietly burned money on Day 1.
    #
    # no_public_ip = false -> nodes get public IPs, no NAT gateway, no standing
    #                         charge. Wrong for production, correct for a lab you
    #                         tear down nightly.
    #
    # Changing this later FORCES REPLACEMENT of the workspace, which orphans
    # everything inside it. Decide now, not on Day 6.
    no_public_ip = var.secure_cluster_connectivity
  }

  tags = merge(local.tags, { environment = each.key })
}

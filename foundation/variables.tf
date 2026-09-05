# Input variables for the foundation module.
#
# Everything here has a default, because this is a single-operator lab and
# prompting for six values on every apply is friction with no upside. In a team
# repo you would strip most of these defaults and force them in a tfvars file
# per environment.

variable "subscription_id" {
  description = "Target subscription. Pinned so a stale `az account set` cannot redirect an apply."
  type        = string
  default     = "c8d01b1f-227b-44a0-ae3e-0e0480fb212e" # Azure Learning
}

variable "location" {
  description = "Azure region. Locked to centralindia - the UC metastore is one-per-region, so this is expensive to change later."
  type        = string
  default     = "centralindia"
}

variable "resource_group_name" {
  description = "Lab resource group. Convention: rg-lab<NN>-<topic>."
  type        = string
  default     = "rg-lab01-foundation"
}

variable "storage_account_name" {
  description = "ADLS Gen2 account. Globally unique across all of Azure, so this carries a personal suffix."
  type        = string
  default     = "stdatalakebhanu7391"

  # Catch the naming rule at plan time instead of 40 seconds into an apply.
  # 3-24 characters, lowercase letters and digits only - no hyphens, no
  # underscores, no uppercase. Storage accounts are the strictest namespace in
  # Azure and the rule is not obvious from the error message you get without it.
  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage account name must be 3-24 characters, lowercase letters and digits only."
  }
}

variable "containers" {
  description = "Filesystems to create in the lake. Medallion layers plus landing and checkpoints."
  type        = list(string)
  default     = ["landing", "bronze", "silver", "gold", "checkpoints", "managed-dev", "managed-prod"]
}

variable "tags" {
  description = "Applied to every resource in this module."
  type        = map(string)
  default = {
    purpose = "databricks-lab"
    owner   = "bhanu"

    # Load-bearing. The teardown routine filters on autodelete=true, which is
    # why rg-terraform-state is tagged autodelete=false and this group is not.
    # Get this wrong and you either lose your state or pay for an idle lab.
    autodelete = "true"
  }
}

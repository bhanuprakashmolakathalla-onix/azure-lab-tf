variable "subscription_id" {
  description = "Target subscription."
  type        = string
  default     = "c8d01b1f-227b-44a0-ae3e-0e0480fb212e"
}

# Two workspaces, because catalog BINDING is meaningless with one. The whole
# point is proving that a catalog attached to `dev` is invisible from `prod`.
#
# Both are premium and both sit in the same resource group and region, so they
# share one metastore - which is exactly the situation binding exists to control.
variable "workspace_names" {
  description = "Environments to create a workspace for. Map key becomes the environment label."
  type        = map(string)
  default = {
    dev  = "dbw-lab01-dev"
    prod = "dbw-lab01-prod"
  }
}

variable "sku" {
  description = "Workspace tier. MUST be premium - Unity Catalog, cluster policies and RBAC are all premium-only."
  type        = string
  default     = "premium"

  validation {
    condition     = contains(["standard", "premium"], var.sku)
    error_message = "sku must be standard or premium (trial exists but expires in 14 days)."
  }
}

# THE cost lever in this whole repo. Read the comment in main.tf before changing.
variable "secure_cluster_connectivity" {
  description = "Enable SCC / no-public-IP clusters. true deploys a NAT gateway at roughly Rs 100/day."
  type        = bool
  default     = false
}

variable "state_storage_account_name" {
  description = "Where the foundation module keeps its state."
  type        = string
  default     = "sttfstatebhanu7391"
}

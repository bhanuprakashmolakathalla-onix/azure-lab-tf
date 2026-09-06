variable "subscription_id" {
  type    = string
  default = "c8d01b1f-227b-44a0-ae3e-0e0480fb212e"
}

variable "location" {
  type    = string
  default = "centralindia"
}

variable "resource_group_name" {
  type    = string
  default = "rg-lab01-serving"
}

variable "state_storage_account_name" {
  type    = string
  default = "sttfstatebhanu7391"
}

variable "databricks_account_id" {
  type    = string
  default = "2622394d-fa97-430e-a285-3ead22358fd1"
}

variable "azure_tenant_id" {
  type    = string
  default = "56ea4fc9-7ab6-41c9-a1c1-e619887446dd"
}

variable "acr_name" {
  description = "Globally unique, alphanumeric only."
  type        = string
  default     = "acrtaxibhanu7391"

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.acr_name))
    error_message = "ACR names are alphanumeric only - no hyphens, unlike almost every other Azure resource."
  }
}

variable "image_tag" {
  description = "Tag built by `az acr build`. Bump it to deploy a new revision."
  type        = string
  default     = "v1"
}

# THE COST LEVER for the serving tier.
#
#   "cluster"   single-node all-purpose. ~Rs 35-40/hr, ~6 MINUTE cold start.
#               Right for a lab: start it, demo, kill it.
#
#   "warehouse" 2X-Small serverless SQL. ~Rs 250/hr, ~10 SECOND cold start.
#               Right for anything a person waits on, and what a real serving
#               tier uses. Warehouses are also built for concurrency; an
#               all-purpose cluster is not.
#
# The application code is identical either way - only the HTTP path differs.
variable "serving_compute" {
  type    = string
  default = "cluster"

  validation {
    condition     = contains(["cluster", "warehouse"], var.serving_compute)
    error_message = "serving_compute must be cluster or warehouse."
  }
}

variable "catalog" {
  type    = string
  default = "dev"
}

variable "tags" {
  type = map(string)
  default = {
    purpose    = "databricks-lab"
    owner      = "bhanu"
    autodelete = "true"
  }
}

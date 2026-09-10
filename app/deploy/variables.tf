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
  default     = "acrfashionbhanu7391"

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.acr_name))
    error_message = "ACR names are alphanumeric only - no hyphens, unlike almost every other Azure resource."
  }
}

# THE LARGEST AVOIDABLE LINE ON A ONE-DAY BILL.
#
# Premium buys a private endpoint for the image pull and costs roughly ten times
# Basic per day. Everything else these two sites use is in Basic, and the public
# endpoint is Entra-authenticated with admin access disabled - there is no key to
# leak, only a path that exists.
#
# Production wants Premium: an image pull happens on every scale-out, and in a
# regulated environment that traffic should not leave the VNet at all. A lab
# that is destroyed the same evening does not.
variable "acr_sku" {
  type    = string
  default = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku must be Basic, Standard or Premium. Only Premium supports private endpoints."
  }
}

variable "image_name" {
  type    = string
  default = "fashion-app"
}

variable "image_tag" {
  description = "Tag built by `az acr build`. Bump it to deploy a new revision of BOTH sites - they share one image."
  type        = string
  default     = "v1"
}

# The ONLY guard on the two public ingress FQDNs. A Container Apps ingress with
# no restriction is reachable by the entire internet, and the console can cancel
# orders.
variable "allowed_source_ip" {
  description = "Public IP permitted to reach both sites. Same value as the jumpbox NSG rule."
  type        = string
  default     = "106.222.203.222"
}

# THE COST LEVER for the serving tier.
#
#   "warehouse" 2X-Small SERVERLESS SQL. ~Rs 250/hr while running, ~10 SECOND
#               cold start, scales to zero. What a real serving tier uses, and
#               the only option that serves BOTH sites under their own
#               identities.
#
#               CAVEAT specific to this build: serverless compute runs in
#               Databricks' network, NOT your VNet. The lake's firewall denies
#               everything except the Access Connector resource instance, so
#               whether serverless can read the lake depends on that exception
#               covering it. If queries fail with a storage authorization error,
#               that is the cause - and the fix is either a network connectivity
#               configuration with private endpoint rules, or switching this
#               variable to "cluster".
#
#   "cluster"   single-node all-purpose, IN your VNet, reaching the lake over
#               the private endpoints already proven to work. ~Rs 45/hr, ~6
#               MINUTE cold start, and SINGLE_USER mode pins it to one principal
#               so only the storefront can use it.
#
# The application code is identical either way - only the HTTP path differs.
variable "serving_compute" {
  type    = string
  default = "warehouse"

  validation {
    condition     = contains(["cluster", "warehouse"], var.serving_compute)
    error_message = "serving_compute must be cluster or warehouse."
  }
}

variable "warehouse_auto_stop_mins" {
  description = "Idle shutdown for the serverless warehouse. The warehouse bills only while running, so this is the tail on every browsing session."
  type        = number
  default     = 10

  validation {
    condition     = var.warehouse_auto_stop_mins >= 5
    error_message = "Databricks will not accept an auto-stop below 5 minutes on a serverless warehouse."
  }
}

# Pinned for the same reason the pipeline's is - see data/pipelines. Must clear
# Azure capacity, Azure quota, AND the Databricks supported-node list.
variable "node_type_id" {
  type    = string
  default = "Standard_D4ds_v5"
}

variable "catalog" {
  type    = string
  default = "fashion"
}

variable "brand_name" {
  type    = string
  default = "MERIDIAN"
}

variable "tags" {
  type = map(string)
  default = {
    purpose    = "fashion-private"
    owner      = "bhanu"
    autodelete = "true"
  }
}

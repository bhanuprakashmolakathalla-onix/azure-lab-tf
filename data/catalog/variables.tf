variable "state_storage_account_name" {
  type    = string
  default = "sttfstatebhanu7391"
}

variable "catalog_name" {
  description = "One catalog for the fashion platform. Environments are schemas' problem, not this lab's."
  type        = string
  default     = "fashion"
}

# bronze/silver/gold are the medallion layers, written by the pipeline and read
# by everything.
#
# `ops` is deliberately NOT one of them. It holds the order book the storefront
# writes at checkout and the console updates as orders move - application state
# arriving one row at a time from outside the lakehouse, not a layer derived from
# the layer above it. Putting it in gold would make a mart that no pipeline run
# produces and no rebuild can reconstruct.
#
# BE HONEST ABOUT THE SHAPE: Delta is a poor transactional store. Every insert is
# a new commit and a new file, and a real storefront would write orders to
# Postgres or Cosmos DB and land them here by change data capture. At this
# volume - a handful of orders in a sitting - the direct write is fine, and it
# is what makes the write-path identity gates visible end to end.
variable "schemas" {
  description = "Medallion layers plus the ops schema that holds the order book."
  type        = list(string)
  default     = ["bronze", "silver", "gold", "ops"]
}

variable "databricks_account_id" {
  description = "Databricks account ID, from the account console user menu."
  type        = string
  default     = "2622394d-fa97-430e-a285-3ead22358fd1"
}

variable "owner_user_name" {
  description = "Your Databricks login, added to the engineers group so grants are testable."
  type        = string
  default     = "bhanuprakash.molakathalla@gmail.com"
}

variable "azure_tenant_id" {
  description = "Entra tenant. REQUIRED on the account-level provider - it defaults to /common, which resolves an MSA-backed login to the consumer tenant and fails AADSTS70011."
  type        = string
  default     = "56ea4fc9-7ab6-41c9-a1c1-e619887446dd"
}

variable "ci_application_id" {
  description = "Entra appId of the CI service principal, from bootstrap-ci-identity.ps1. NOT the SP object id."
  type        = string
  default     = "399c031a-6a58-4b51-9423-db05f87fa3bc"
}

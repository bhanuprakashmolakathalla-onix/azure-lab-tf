variable "state_storage_account_name" {
  type    = string
  default = "sttfstatebhanu7391"
}

variable "schemas" {
  description = "Medallion layers, created identically in every environment catalog."
  type        = list(string)
  default     = ["bronze", "silver", "gold"]
}

variable "databricks_account_id" {
  description = "Databricks account ID. Discovered with `databricks auth describe`, or from the account console user menu."
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

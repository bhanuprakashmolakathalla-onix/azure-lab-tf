variable "subscription_id" {
  type    = string
  default = "c8d01b1f-227b-44a0-ae3e-0e0480fb212e"
}

variable "monthly_budget_inr" {
  description = "Monthly cap. Alerts only - Azure budgets NOTIFY, they never stop spend."
  type        = number
  default     = 15000
}

variable "alert_email" {
  type    = string
  default = "bhanuprakash.molakathalla@gmail.com"
}

variable "databricks_account_id" {
  type    = string
  default = "2622394d-fa97-430e-a285-3ead22358fd1"
}

variable "azure_tenant_id" {
  description = "REQUIRED on the account-level provider - it defaults to /common, which fails AADSTS70011 for an MSA-backed identity."
  type        = string
  default     = "56ea4fc9-7ab6-41c9-a1c1-e619887446dd"
}

variable "ci_application_id" {
  description = "Entra appId of the CI service principal, from bootstrap-ci-identity.ps1."
  type        = string
  default     = "399c031a-6a58-4b51-9423-db05f87fa3bc"
}

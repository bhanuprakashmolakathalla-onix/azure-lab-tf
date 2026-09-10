variable "state_storage_account_name" {
  type    = string
  default = "sttfstatebhanu7391"
}

variable "ci_application_id" {
  description = "Service principal the job RUNS AS. Not a person."
  type        = string
  default     = "399c031a-6a58-4b51-9423-db05f87fa3bc"
}

variable "catalog" {
  description = "Unity Catalog the pipeline writes into."
  type        = string
  default     = "fashion"
}

variable "start_date" {
  description = "First day of generated history."
  type        = string
  default     = "2026-08-01"
}

variable "num_days" {
  description = "Days of history. 28 gives four weekend cycles, which is what makes weekly seasonality visible in gold."
  type        = string
  default     = "28"
}

variable "state_storage_account_name" {
  type    = string
  default = "sttfstatebhanu7391"
}

variable "ci_application_id" {
  description = "Service principal the jobs RUN AS. Not a person."
  type        = string
  default     = "399c031a-6a58-4b51-9423-db05f87fa3bc"
}

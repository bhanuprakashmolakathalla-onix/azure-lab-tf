variable "state_storage_account_name" {
  type    = string
  default = "sttfstatebhanu7391"
}

variable "single_user_name" {
  description = "Databricks principal that owns the single-user cluster. Must match your Databricks login exactly."
  type        = string
  default     = "bhanuprakash.molakathalla@gmail.com"
}

variable "autotermination_minutes" {
  description = "Idle shutdown. The single most important cost control on this page."
  type        = number
  default     = 20
}

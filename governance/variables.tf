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

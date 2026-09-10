variable "state_storage_account_name" {
  type    = string
  default = "sttfstatebhanu7391"
}

variable "single_user_name" {
  description = "Databricks principal that owns the single-user cluster. Must match your Databricks login exactly - the same value data/catalog uses for owner_user_name."
  type        = string
  default     = "bhanuprakash.molakathalla@gmail.com"
}

variable "autotermination_minutes" {
  description = "Idle shutdown. The single most important cost control on this page."
  type        = number
  default     = 20
}

# Pinned for the same reason data/pipelines pins its own - see the note in
# main.tf. Must clear Azure capacity, Azure quota, AND the Databricks
# supported-node list.
variable "node_type_id" {
  type    = string
  default = "Standard_D4ds_v5"
}

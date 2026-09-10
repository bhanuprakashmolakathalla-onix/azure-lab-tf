variable "catalog" {
  description = "Unity Catalog the pipeline writes into. One catalog now, so this is no longer an environment name."
  type        = string
}

variable "ci_application_id" {
  description = "Service principal the job runs as."
  type        = string
}

variable "notebook_root" {
  description = "Workspace folder for the notebooks."
  type        = string
  default     = "/Shared/fashion"
}

variable "landing_url" {
  description = "abfss:// URL of the landing container. Auto Loader watches fashion/<stream>/ beneath it."
  type        = string
}

variable "checkpoints_url" {
  description = "abfss:// URL for Auto Loader schema and commit state. Operational state, deliberately NOT in a medallion layer - it is not data, and it must survive independently of any table."
  type        = string
}

variable "start_date" {
  description = "First day of generated history."
  type        = string
  default     = "2026-08-01"
}

variable "num_days" {
  description = "Days of history to generate. 28 gives four weekend cycles, which is what makes the weekly seasonality visible in gold."
  type        = string
  default     = "28"
}

variable "node_type_id" {
  description = "Cluster node SKU. PINNED, not discovered - see the note in main.tf. Must clear BOTH az vm list-skus (capacity) and az vm list-usage (quota) in your region."
  type        = string
  default     = "Standard_D4ds_v5"
}

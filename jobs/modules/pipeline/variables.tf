variable "env" {
  description = "Environment name. Doubles as the target catalog."
  type        = string
}

variable "ci_application_id" {
  description = "Service principal the job runs as."
  type        = string
}

variable "notebook_root" {
  description = "Workspace folder for the notebooks."
  type        = string
  default     = "/Shared/medallion"
}

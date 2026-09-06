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

variable "landing_url" {
  description = "abfss:// URL of the landing container. Auto Loader watches a subdirectory of this."
  type        = string
}

variable "checkpoints_url" {
  description = "abfss:// URL for Auto Loader schema and commit state. Operational state, deliberately NOT in a medallion layer."
  type        = string
}

variable "seed_batch" {
  description = "Which simulated batch the seed task writes. Bump it to make new files appear, then re-run the job - Auto Loader should ingest ONLY the new batch."
  type        = string
  default     = "1"
}

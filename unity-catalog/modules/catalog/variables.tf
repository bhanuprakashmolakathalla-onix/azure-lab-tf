variable "name" {
  description = "Catalog name, which is also the environment name."
  type        = string
}

variable "storage_root" {
  description = "abfss:// URL for this catalog's managed tables. IMMUTABLE once set."
  type        = string
}

variable "workspace_id" {
  description = "Numeric Databricks workspace ID to bind to - NOT the ARM resource ID."
  type        = string
}

variable "schemas" {
  description = "Schemas to create inside the catalog."
  type        = list(string)
}

variable "read_only_workspace_ids" {
  description = "Extra workspaces that may READ this catalog but never write to it. Map of label -> numeric workspace id."
  type        = map(string)
  default     = {}
}

variable "catalog_grants" {
  description = "principal -> privileges at CATALOG level. Inherited by every schema and table beneath."
  type        = map(list(string))
  default     = {}
}

variable "schema_grants" {
  description = "principal -> privileges applied to every schema in this catalog."
  type        = map(list(string))
  default     = {}
}

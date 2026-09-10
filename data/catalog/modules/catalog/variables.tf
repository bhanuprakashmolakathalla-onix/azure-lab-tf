variable "name" {
  description = "Catalog name."
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

variable "owner" {
  description = "Group that owns the catalog and its schemas. A GROUP, never a person - see the platform_admins comment in the root module."
  type        = string
}

variable "read_only_workspace_ids" {
  description = "Extra workspaces that may READ this catalog but never write to it. Map of label -> numeric workspace id."
  type        = map(string)
  default     = {}
}

variable "catalog_grants" {
  description = "principal -> privileges at CATALOG level. Inherited by every schema and table beneath, so keep this to traversal and creation rights wherever possible."
  type        = map(list(string))
  default     = {}
}

# schema -> principal -> privileges.
#
# Two levels, because this is where the medallion layers stop being uniform.
# Analysts have no business in bronze; the storefront has no business anywhere
# except gold and ops. A flat principal -> privileges map could only express
# "the same everywhere", which is the policy you write when the mechanism cannot
# express anything better.
variable "schema_grants" {
  description = "schema name -> principal -> privileges. Applied only to the named schema."
  type        = map(map(list(string)))
  default     = {}
}

variable "subscription_id" {
  type    = string
  default = "c8d01b1f-227b-44a0-ae3e-0e0480fb212e"
}

variable "location" {
  type    = string
  default = "centralindia"
}

# TWO resource groups, and the reason is forced rather than organisational.
#
# Front-end and back-end private endpoints both target the sub-resource
# `databricks_ui_api`, so both need a private DNS zone named exactly
# `privatelink.azuredatabricks.net` - resolving the SAME hostname to DIFFERENT
# addresses depending on whether a user or a cluster is asking.
#
# Azure requires zone names to be unique within a resource group but allows
# duplicates across them. Two zones of that name therefore means two resource
# groups. The split is what makes the architecture expressible at all.
variable "transit_resource_group" {
  type    = string
  default = "rg-lab01-transit"
}

variable "workspace_resource_group" {
  type    = string
  default = "rg-lab01-network"
}

variable "transit_address_space" {
  type    = string
  default = "10.10.0.0/16"
}

variable "workspace_address_space" {
  type    = string
  default = "10.20.0.0/16"
}

variable "tags" {
  type = map(string)
  default = {
    purpose    = "fashion-private"
    owner      = "bhanu"
    autodelete = "true"
  }
}

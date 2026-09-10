variable "subscription_id" {
  type    = string
  default = "c8d01b1f-227b-44a0-ae3e-0e0480fb212e"
}

variable "state_storage_account_name" {
  type    = string
  default = "sttfstatebhanu7391"
}

# ONE workspace now, not two.
#
# The dev/prod isolation exercise is done and documented. A second private
# workspace would double the private-endpoint count and the DNS wiring to
# demonstrate something already proven.
variable "workspace_name" {
  type    = string
  default = "dbw-fashion"
}

variable "tags" {
  type = map(string)
  default = {
    purpose    = "fashion-private"
    owner      = "bhanu"
    autodelete = "true"
  }
}

variable "subscription_id" {
  type    = string
  default = "c8d01b1f-227b-44a0-ae3e-0e0480fb212e"
}

variable "state_storage_account_name" {
  type    = string
  default = "sttfstatebhanu7391"
}

# THE guardrail on this machine. A jumpbox with RDP open to the internet is a
# worse hole than the one the private networking closed - it is a credential
# away from full access to everything private.
variable "allowed_source_ip" {
  description = "Your public IP. RDP is permitted from here and nowhere else."
  type        = string

  # Catch a placeholder at PLAN time rather than letting it become an NSG rule.
  #
  # `-var="allowed_source_ip=<your ip>"` copied straight out of a README is
  # accepted by Terraform, plans four resources cleanly, and produces a firewall
  # rule for a source address that cannot exist. Nothing errors, and the machine
  # is simply unreachable - a failure that looks like networking and is not.
  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.allowed_source_ip))
    error_message = "allowed_source_ip must be a bare IPv4 address with no mask - the /32 is added for you. Get it with: (Invoke-RestMethod https://api.ipify.org).Trim()"
  }
}

# No default, and never committed. Terraform state does hold it, which is why
# the state account has shared keys disabled and Entra-only access.
variable "admin_password" {
  description = "Local administrator password for the jumpbox."
  type        = string
  sensitive   = true

  # AZURE'S RULE, ENFORCED HERE INSTEAD OF THERE.
  #
  # Azure wants 12-123 characters and THREE of these four: lowercase, uppercase,
  # a digit, a special character. Left to Azure, that check happens after the
  # whole plan has been built and printed - the error arrives at the very last
  # resource, under a wall of green plan output nobody reads twice.
  #
  # Same argument as the storage account name validation in foundation: a rule
  # that is knowable at plan time should fail at plan time.
  validation {
    condition = length(var.admin_password) >= 12 && length(var.admin_password) <= 123 && (
      (can(regex("[a-z]", var.admin_password)) ? 1 : 0) +
      (can(regex("[A-Z]", var.admin_password)) ? 1 : 0) +
      (can(regex("[0-9]", var.admin_password)) ? 1 : 0) +
      (can(regex("[^a-zA-Z0-9_]", var.admin_password)) ? 1 : 0)
    ) >= 3
    error_message = "admin_password must be 12-123 characters and satisfy 3 of 4: lowercase, uppercase, digit, special character other than underscore."
  }
}

variable "admin_username" {
  type    = string
  default = "labadmin"
}

# THE SKU HUNT, recorded so nobody repeats it. Azure gates a VM on TWO separate
# limits and an allocation needs BOTH:
#   capacity  az vm list-skus  -> SkuNotAvailable, no hardware, no ticket helps
#   quota     az vm list-usage -> OperationNotAllowed, raisable by request
#
#
# In CentralIndia on this subscription: BS has quota 10 and no capacity; Bsv2
# and DSv5 have capacity and quota 0. EBSv5 is the only v5 family that clears
# both. E4bs_v5: 4 vCPU, 32 GiB, Gen2, trusted-launch capable, ~Rs 33/hour with
# Windows. E2bs_v5 (2 vCPU) was unusably slow under Windows Server. E8bs_v5 does
# NOT fit: Total Regional vCPUs is 10, and the Databricks single-node cluster
# needs 4 of them.
# Avoid any SKU with a "p" (D2ps_v5, B2ps_v2): that marks ARM64, and no Windows
# Server ARM64 image exists. Total Regional vCPUs is capped at 10 regardless.
variable "vm_size" {
  type    = string
  default = "Standard_E4bs_v5"
}

variable "tags" {
  type = map(string)
  default = {
    purpose    = "fashion-private"
    owner      = "bhanu"
    autodelete = "true"
  }
}

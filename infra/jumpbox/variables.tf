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
}

# No default, and never committed. Terraform state does hold it, which is why
# the state account has shared keys disabled and Entra-only access.
variable "admin_password" {
  description = "Local administrator password for the jumpbox."
  type        = string
  sensitive   = true
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

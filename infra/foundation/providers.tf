# Provider wiring for the foundation module.
#
# GCP comparison: there is no `project` argument here, because there is no
# equivalent. The SUBSCRIPTION is the boundary, and it gets pinned explicitly
# below. Authentication rides your `az login` session the same way the google
# provider rides ADC - there are no keys anywhere in this repo.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Pessimistic constraint: take 4.x patches and minors, never 5.x.
      # AzureRM makes breaking changes on majors and does it often.
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  # REQUIRED as of azurerm 4.x. In 3.x the provider silently inherited whatever
  # subscription `az account show` happened to be pointing at, which is exactly
  # how people deploy into the wrong subscription and only find out later.
  # 4.x forced it to be explicit. ARM_SUBSCRIPTION_ID works too, but pinning it
  # in code is the whole point.
  subscription_id = var.subscription_id

  # Mandatory, even when empty. This is where destroy-time behaviour is tuned -
  # by default a resource group refuses to delete while it still holds resources
  # Terraform does not know about, which is a guardrail worth keeping.
  features {}

  # The one that will bite you if you omit it.
  #
  # bootstrap-backend.ps1 created the state account with
  # --allow-shared-key-access false, and the lab storage account does the same.
  # Without this flag the provider reaches for an ACCOUNT KEY to do data-plane
  # work - creating containers, writing blobs - and fails with a 403 that reads
  # like a networking or firewall problem. This tells it to use your Entra token
  # instead. Same control-plane / data-plane split that cost you time on Day 1,
  # showing up one layer down.
  storage_use_azuread = true

  # Providers were registered on Day 1 and registration is subscription-wide,
  # not per-module. Re-checking all of them on every `terraform init` is pure
  # latency, and the check needs permissions a CI service principal may not have.
  resource_provider_registrations = "none"
}

<#
.SYNOPSIS
    One-time bootstrap of the Terraform remote state backend.

.DESCRIPTION
    The chicken-and-egg problem: Terraform needs somewhere to keep state, but you
    cannot Terraform the thing that holds your state. So this one piece stays
    imperative. Everything after this is code.

    Creates a dedicated resource group + storage account for tfstate, deliberately
    SEPARATE from any lab resource group, so that `terraform destroy` or a careless
    `az group delete` can never take your state file with it.

    GCP comparison: this is the equivalent of creating a GCS bucket for a
    `backend "gcs"` block. The difference that matters is auth - GCS backends
    normally ride your ADC credentials, whereas the azurerm backend historically
    defaulted to a shared ACCOUNT KEY. We disable shared keys entirely and use
    Entra ID auth instead (use_azuread_auth = true), which is the modern posture.

.NOTES
    Idempotent - safe to re-run. Costs roughly Rs 5/month for a nearly empty
    storage account. Do NOT tag this autodelete=true.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId = "c8d01b1f-227b-44a0-ae3e-0e0480fb212e",
    [string]$Location       = "centralindia",
    [string]$ResourceGroup  = "rg-terraform-state",
    [string]$Container      = "tfstate",

    # Storage account names are GLOBALLY unique, 3-24 chars, lowercase alphanumeric
    # only. Change this if creation fails with a name-taken error.
    [string]$StorageAccount = "sttfstatebhanu7391"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Terraform backend bootstrap ===" -ForegroundColor Cyan

# --- Preflight ------------------------------------------------------------
# Fail early and loudly rather than half-creating things.

Write-Host "`n[1/6] Checking az login..."
try {
    $acct = az account show --output json 2>$null | ConvertFrom-Json
    if (-not $acct) { throw "not logged in" }
} catch {
    throw "Not logged into Azure. Run: az login"
}

Write-Host "      Logged in as : $($acct.user.name)"

Write-Host "`n[2/6] Selecting subscription $SubscriptionId ..."
az account set --subscription $SubscriptionId
$acct = az account show --output json | ConvertFrom-Json
if ($acct.id -ne $SubscriptionId) { throw "Failed to select subscription $SubscriptionId" }
if ($acct.state -ne "Enabled")    { throw "Subscription state is '$($acct.state)', expected 'Enabled'" }
Write-Host "      Subscription : $($acct.name)  [$($acct.state)]"

# --- Resource group -------------------------------------------------------

Write-Host "`n[3/6] Resource group '$ResourceGroup' ..."
$rgExists = az group exists --name $ResourceGroup --output tsv
if ($rgExists -eq "true") {
    Write-Host "      Already exists - skipping"
} else {
    # NOTE the tags: autodelete=false. The nightly teardown script filters on
    # autodelete=true, so this group is deliberately excluded from it.
    az group create `
        --name $ResourceGroup `
        --location $Location `
        --tags purpose=terraform-state owner=bhanu autodelete=false `
        --output none
    Write-Host "      Created"
}

# --- Storage account ------------------------------------------------------

Write-Host "`n[4/6] Storage account '$StorageAccount' ..."
$saExists = az storage account list `
    --resource-group $ResourceGroup `
    --query "[?name=='$StorageAccount'] | length(@)" `
    --output tsv

if ($saExists -eq "1") {
    Write-Host "      Already exists - skipping"
} else {
    # --allow-shared-key-access false : no account keys at all. The backend will
    #   authenticate with your Entra token instead (use_azuread_auth = true).
    #   This is why the backend.tf you generate below does NOT contain a secret.
    #
    # Blob VERSIONING is the important one here. Terraform state is the single
    # most destructive file in your repo to lose or corrupt. Versioning gives you
    # point-in-time recovery of every state write, which has saved more engineers
    # than any other single setting in this file.
    #
    # NOTE: hierarchical namespace is intentionally NOT enabled. That is for the
    # data lake. A state backend wants plain blob storage.
    az storage account create `
        --name $StorageAccount `
        --resource-group $ResourceGroup `
        --location $Location `
        --sku Standard_LRS `
        --kind StorageV2 `
        --min-tls-version TLS1_2 `
        --allow-blob-public-access false `
        --allow-shared-key-access false `
        --output none

    az storage account blob-service-properties update `
        --account-name $StorageAccount `
        --resource-group $ResourceGroup `
        --enable-versioning true `
        --enable-delete-retention true `
        --delete-retention-days 30 `
        --output none

    Write-Host "      Created (versioning on, 30-day soft delete, shared keys disabled)"
}

# --- Data-plane RBAC ------------------------------------------------------

Write-Host "`n[5/6] Granting yourself data-plane access ..."
# Day 1 lesson, encoded: Owner is a CONTROL-plane role. It lets you create and
# configure this storage account but grants you no ability to read or write a
# single blob. Terraform needs to read and write blobs. So we assign an explicit
# data-plane role. Omit this and `terraform init` fails with a 403 that looks
# like a backend misconfiguration.
$oid   = az ad signed-in-user show --query id --output tsv
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$StorageAccount"

$hasRole = az role assignment list `
    --assignee $oid `
    --scope $scope `
    --query "[?roleDefinitionName=='Storage Blob Data Contributor'] | length(@)" `
    --output tsv

if ($hasRole -eq "0") {
    az role assignment create `
        --assignee-object-id $oid `
        --assignee-principal-type User `
        --role "Storage Blob Data Contributor" `
        --scope $scope `
        --output none
    Write-Host "      Assigned Storage Blob Data Contributor"
    Write-Host "      Waiting 60s for Entra RBAC propagation..." -ForegroundColor Yellow
    # Azure RBAC is eventually consistent. Retrying in 3 seconds and seeing the
    # same 403 is how people conclude a correct role assignment 'did not work'.
    Start-Sleep -Seconds 60
} else {
    Write-Host "      Already assigned - skipping"
}

# --- Container ------------------------------------------------------------

Write-Host "`n[6/6] Container '$Container' ..."
az storage container create `
    --name $Container `
    --account-name $StorageAccount `
    --auth-mode login `
    --output none
Write-Host "      Ready"

# --- Emit backend config --------------------------------------------------

$backend = @"
# GENERATED by bootstrap-backend.ps1 - do not edit by hand.
#
# No access key, no connection string, no secret. Authentication is your Entra
# identity via use_azuread_auth. This file is safe to commit.
terraform {
  backend "azurerm" {
    resource_group_name  = "$ResourceGroup"
    storage_account_name = "$StorageAccount"
    container_name       = "$Container"
    key                  = "foundation.tfstate"
    use_azuread_auth     = true
  }
}
"@

$outPath = Join-Path $PSScriptRoot "foundation\backend.tf"
New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
# WriteAllText, not Out-File: PowerShell 5.1 writes a UTF-8 BOM that some
# tooling chokes on. .NET's WriteAllText defaults to UTF-8 without BOM.
[System.IO.File]::WriteAllText($outPath, $backend)

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "Backend config written to: $outPath"
Write-Host ""
Write-Host "State storage : $StorageAccount / $Container"
Write-Host "Cost          : ~Rs 5/month"
Write-Host ""
Write-Host "Next: cd foundation ; terraform init"

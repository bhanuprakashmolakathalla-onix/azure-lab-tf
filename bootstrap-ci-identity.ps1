<#
.SYNOPSIS
    One-time creation of the CI service principal that runs Terraform.

.DESCRIPTION
    Second bootstrap, same reasoning as the first. Terraform running AS this
    identity cannot be the thing that creates it, so this stays imperative.
    Everything the identity then does is code.

    What this deliberately does NOT do: grant Owner. See the role section.

.NOTES
    Idempotent. Costs nothing. The client secret is printed ONCE and never
    recoverable - if you lose it, re-run with -ResetSecret.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId  = "c8d01b1f-227b-44a0-ae3e-0e0480fb212e",
    [string]$DisplayName     = "sp-terraform-lab",
    [string]$StateResourceGroup = "rg-terraform-state",
    [string]$StateAccount    = "sttfstatebhanu7391",
    [switch]$ResetSecret
)

$ErrorActionPreference = "Stop"
Write-Host "=== CI identity bootstrap ===" -ForegroundColor Cyan

# --- App registration -----------------------------------------------------
# In Entra an "app registration" and a "service principal" are two objects, not
# one. The APPLICATION is the global definition; the SERVICE PRINCIPAL is its
# instance inside your tenant, and it is the SP that holds role assignments.
#
# GCP comparison: a GCP service account is a single object that is both. Azure
# splitting them is why `az ad app create` alone gives you something that cannot
# log in, and why the appId and the SP objectId are different GUIDs you will mix
# up at least once.

Write-Host "`n[1/5] App registration '$DisplayName' ..."
$appId = az ad app list --display-name $DisplayName --query "[0].appId" --output tsv

if ([string]::IsNullOrWhiteSpace($appId)) {
    $appId = az ad app create --display-name $DisplayName --query appId --output tsv
    Write-Host "      Created  appId: $appId"
} else {
    Write-Host "      Exists   appId: $appId"
}

Write-Host "`n[2/5] Service principal ..."
$spObjectId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" --output tsv
if ([string]::IsNullOrWhiteSpace($spObjectId)) {
    $spObjectId = az ad sp create --id $appId --query id --output tsv
    Write-Host "      Created  objectId: $spObjectId"
    Write-Host "      Waiting 30s for Entra replication..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30
} else {
    Write-Host "      Exists   objectId: $spObjectId"
}

# --- Azure roles ----------------------------------------------------------
# NOT Owner. Owner is a wildcard and hands your CI pipeline the ability to grant
# itself anything, which is the single most common over-privilege in cloud CI.
#
# Two narrower roles instead:
#
#   Contributor
#     Create and manage resources. Explicitly EXCLUDES
#     Microsoft.Authorization/*/write, so it cannot hand out permissions.
#
#   Role Based Access Control Administrator
#     Can create role assignments and nothing else. The foundation module needs
#     this - it assigns Storage Blob Data Contributor to the Access Connector.
#     Without it that apply fails with AuthorizationFailed on the role
#     assignment, several minutes in, after the storage account already exists.
#
#     This is narrower than the older User Access Administrator, which could also
#     read and manage other people's access.
Write-Host "`n[3/5] Subscription roles ..."
$subScope = "/subscriptions/$SubscriptionId"

foreach ($role in @("Contributor", "Role Based Access Control Administrator")) {
    # NOTE: no length(@) here. Parentheses are cmd metacharacters and az is a
    # .cmd shim, so a JMESPath function call in --query can be torn apart before
    # az ever sees it. Return ids and count them in PowerShell instead.
    $has = az role assignment list --assignee $spObjectId --scope $subScope `
             --query "[?roleDefinitionName=='$role'].id" --output tsv
    if ([string]::IsNullOrWhiteSpace($has)) {
        az role assignment create --assignee-object-id $spObjectId `
            --assignee-principal-type ServicePrincipal `
            --role $role --scope $subScope --output none
        Write-Host "      Assigned $role"
    } else {
        Write-Host "      Already  $role"
    }
}

# --- State access ---------------------------------------------------------
# Day 2's lesson again: Contributor is control plane. Reading and writing the
# tfstate BLOB needs an explicit data-plane role, and shared keys are disabled
# on that account so there is no key-based fallback.
Write-Host "`n[4/5] Data-plane access to tfstate ..."
$stateScope = "$subScope/resourceGroups/$StateResourceGroup/providers/Microsoft.Storage/storageAccounts/$StateAccount"
$hasBlob = az role assignment list --assignee $spObjectId --scope $stateScope `
             --query "[?roleDefinitionName=='Storage Blob Data Contributor'].id" --output tsv
if ([string]::IsNullOrWhiteSpace($hasBlob)) {
    az role assignment create --assignee-object-id $spObjectId `
        --assignee-principal-type ServicePrincipal `
        --role "Storage Blob Data Contributor" --scope $stateScope --output none
    Write-Host "      Assigned Storage Blob Data Contributor on $StateAccount"
} else {
    Write-Host "      Already  assigned"
}

# --- Secret ---------------------------------------------------------------
Write-Host "`n[5/5] Client secret ..."
$existing = az ad app credential list --id $appId --query "[].keyId" --output tsv
if (-not [string]::IsNullOrWhiteSpace($existing) -and -not $ResetSecret) {
    Write-Host "      A credential already exists. Re-run with -ResetSecret to mint a new one." -ForegroundColor Yellow
    $secret = $null
} else {
    $secret = az ad app credential reset --id $appId --years 1 --query password --output tsv
    Write-Host "      Created (valid 1 year)"
}

$tenantId = az account show --query tenantId --output tsv

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "appId (client id) : $appId"
Write-Host "SP object id      : $spObjectId"
Write-Host "tenant            : $tenantId"

if ($secret) {
    Write-Host "`nSet these to run Terraform AS the service principal." -ForegroundColor Cyan
    Write-Host "The secret is shown ONCE and cannot be retrieved again.`n" -ForegroundColor Yellow
    Write-Host "`$env:ARM_CLIENT_ID=`"$appId`""
    Write-Host "`$env:ARM_CLIENT_SECRET=`"$secret`""
    Write-Host "`$env:ARM_TENANT_ID=`"$tenantId`""
    Write-Host "`$env:ARM_SUBSCRIPTION_ID=`"$SubscriptionId`""
    Write-Host "`nTo go back to your own identity: close the shell, or clear those four."
}

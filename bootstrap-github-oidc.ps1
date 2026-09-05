<#
.SYNOPSIS
    Replace the CI client secret with GitHub OIDC federation.

.DESCRIPTION
    A client secret is a bearer credential: anyone holding it is the service
    principal, from anywhere, until it expires. Federation removes it entirely.

    Instead, GitHub signs a short-lived token asserting "this workflow run is
    from repo X, on branch Y". Entra is configured to trust that assertion for
    this specific app, from this specific repo and ref. Nothing long-lived
    exists to steal, and a stolen token is useless outside that context.

    GCP comparison: identical in spirit to Workload Identity Federation for
    GitHub Actions. The subject string format is the part to get right in both.

.NOTES
    Run once per subject. Safe to re-run - existing credentials are skipped.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GitHubOwner,
    [Parameter(Mandatory = $true)][string]$GitHubRepo,
    [string]$AppId  = "399c031a-6a58-4b51-9423-db05f87fa3bc",
    [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"
Write-Host "=== GitHub OIDC federation ===" -ForegroundColor Cyan

# Two subjects, because they are different trust decisions.
#
#   ref:refs/heads/main  - runs on the default branch. These APPLY.
#   pull_request         - runs from a PR. These only PLAN.
#
# Keeping them separate is what lets the workflow refuse to apply from a PR,
# enforced by Entra rather than only by workflow logic someone could edit.
$subjects = @(
    @{ name = "github-$GitHubRepo-$Branch"; subject = "repo:$GitHubOwner/${GitHubRepo}:ref:refs/heads/$Branch"; desc = "Apply from $Branch" },
    @{ name = "github-$GitHubRepo-pr";      subject = "repo:$GitHubOwner/${GitHubRepo}:pull_request";           desc = "Plan from pull requests" }
)

$existing = az ad app federated-credential list --id $AppId --query "[].name" --output tsv

foreach ($s in $subjects) {
    if ($existing -split "`n" -contains $s.name) {
        Write-Host "  Already exists: $($s.name)"
        continue
    }

    $body = @{
        name        = $s.name
        issuer      = "https://token.actions.githubusercontent.com"
        subject     = $s.subject
        description = $s.desc
        audiences   = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Compress

    # WriteAllText, not Out-File: PowerShell 5.1 writes a UTF-8 BOM and
    # `az rest`/`--parameters @file` chokes on it.
    $tmp = Join-Path $env:TEMP "fedcred.json"
    [System.IO.File]::WriteAllText($tmp, $body)

    az ad app federated-credential create --id $AppId --parameters "@$tmp" --output none
    Write-Host "  Created: $($s.name)"
    Write-Host "           subject = $($s.subject)"
}

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "Set these as GitHub repository VARIABLES (not secrets - none of them are secret):"
Write-Host "  ARM_CLIENT_ID       = $AppId"
Write-Host "  ARM_TENANT_ID       = $(az account show --query tenantId --output tsv)"
Write-Host "  ARM_SUBSCRIPTION_ID = $(az account show --query id --output tsv)"
Write-Host ""
Write-Host "Then delete the client secret you created on Day 5:" -ForegroundColor Yellow
Write-Host "  az ad app credential delete --id $AppId --key-id <keyId>"
Write-Host "  (list them with: az ad app credential list --id $AppId --query ""[].keyId"" -o tsv)"

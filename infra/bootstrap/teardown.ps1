<#
.SYNOPSIS
    Tear the lab down. Everything except state, the budget and the CI identity.

.DESCRIPTION
    The most important script in the repo, because the platform is cheap to
    rebuild and expensive to forget about. Idle cost with everything running is
    dominated by three things - the jumpbox, the NAT gateway and the container
    registry - and none of them care whether you are using them.

    ORDER IS NOT NEGOTIABLE, and it is the reason this is a script rather than a
    loop over directories.

    The Databricks-side modules must go FIRST, because they hold objects that do
    not live in any Azure resource group: account groups, service principals, a
    metastore-scoped storage credential and its external locations. Delete the
    resource groups first and those are orphaned - still there, still owned by a
    principal, invisible in the portal, and waiting to collide with the next
    rebuild.

    The jumpbox goes AFTER them and not before, because those modules can only
    be reached from inside the VNet. Destroy your way in and you have locked
    yourself out of the rest of the teardown.

    WHAT THIS DELIBERATELY LEAVES:
      rg-terraform-state   your state. Tagged autodelete=false.
      governance           the budget and the CI service principal. A budget
                           that vanishes with the resources it was watching is
                           worse than no budget, and the identity that RUNS
                           Terraform must not be owned by state Terraform
                           destroys.

.PARAMETER Scope
    Databricks : app/deploy, data/pipelines, infra/compute, data/catalog.
                 Must run from the jumpbox.
    Azure      : infra/jumpbox, infra/workspace, infra/foundation, infra/network.
                 Runs from the LAPTOP. It deletes the resource group the jumpbox
                 lives in, so running it there means deleting the machine
                 executing it - the script refuses.
    All        : both, in order. Only useful from the laptop, where the
                 Databricks stage will fail on the first module because the
                 workspace hostname does not resolve. Two invocations from two
                 machines is the normal path.

.PARAMETER Fast
    Replaces the Azure stage with `az group delete` on every resource group
    tagged autodelete=true, in parallel. Roughly four minutes instead of twelve.

    The cost is real: state files are left describing resources that no longer
    exist, so the next apply must start from a clean state. The script empties
    them for you. Use it when you are done for the day, not when you intend to
    apply again in an hour.

.PARAMETER WhatIf
    Print the plan and touch nothing.

.EXAMPLE
    .\teardown.ps1 -Scope All
    .\teardown.ps1 -Scope All -Fast
    .\teardown.ps1 -Scope Azure -WhatIf
#>

[CmdletBinding()]
param(
    [ValidateSet("Databricks", "Azure", "All")]
    [string]$Scope = "All",

    [switch]$Fast,
    [switch]$WhatIf,

    [string]$SubscriptionId = "c8d01b1f-227b-44a0-ae3e-0e0480fb212e",
    [string]$StateResourceGroup = "rg-terraform-state",
    [string]$StateAccount = "sttfstatebhanu7391",
    [string]$StateContainer = "tfstate",

    # Only used to satisfy the jumpbox module's required variables during
    # destroy. Neither value changes what gets deleted - Terraform simply
    # refuses to run with an unset variable, even on a destroy that will not
    # read it.
    [string]$AllowedSourceIp = "",
    [string]$AdminPassword = "TeardownPlaceholder1!"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

# Destroy order. Reverse of the build, and every entry is here because
# something above it depends on something below it.
$databricksStage = @(
    @{ Dir = "app/deploy";     Key = "serving.tfstate";       Why = "container apps, ACR, both app identities" },
    @{ Dir = "data/pipelines"; Key = "jobs.tfstate";          Why = "the medallion job and its notebooks" },
    @{ Dir = "infra/compute";  Key = "compute.tfstate";       Why = "the ad-hoc cluster, if it was ever applied" },
    @{ Dir = "data/catalog";   Key = "unity-catalog.tfstate"; Why = "catalog, external locations, groups - NOT in any resource group" }
)

$azureStage = @(
    @{ Dir = "infra/jumpbox";    Key = "jumpbox.tfstate";    Why = "the VM, its disk and its public address" },
    @{ Dir = "infra/workspace";  Key = "workspace.tfstate";  Why = "the workspace and three private endpoints" },
    @{ Dir = "infra/foundation"; Key = "foundation.tfstate"; Why = "the lake, its containers and the access connector" },
    @{ Dir = "infra/network";    Key = "network.tfstate";    Why = "VNets, NAT gateway, DNS zones, peering" }
)

function Get-Stages {
    switch ($Scope) {
        "Databricks" { return @($databricksStage) }
        "Azure"      { return @($azureStage) }
        default      { return @($databricksStage, $azureStage) }
    }
}

Write-Host "=== Teardown ===" -ForegroundColor Cyan
Write-Host "Scope        : $Scope"
Write-Host "Azure stage  : $(if ($Fast) { 'az group delete (fast)' } else { 'terraform destroy' })"
Write-Host "Preserved    : $StateResourceGroup, governance (budget + CI identity)"
Write-Host ""

# --- Preflight ------------------------------------------------------------

$acct = az account show --output json 2>$null | ConvertFrom-Json
if (-not $acct) { throw "Not logged into Azure. Run: az login" }
if ($acct.id -ne $SubscriptionId) {
    az account set --subscription $SubscriptionId
    Write-Host "Switched subscription to $SubscriptionId"
}
Write-Host "Signed in as : $($acct.user.name)"

if ([string]::IsNullOrWhiteSpace($AllowedSourceIp)) {
    try {
        $AllowedSourceIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 8).Trim()
    } catch {
        $AllowedSourceIp = "0.0.0.0"
    }
}

# --- Plan -----------------------------------------------------------------

$stages = Get-Stages
Write-Host "`nWill destroy, in this order:" -ForegroundColor Yellow
$n = 0
foreach ($stage in $stages) {
    foreach ($m in $stage) {
        $n++
        Write-Host ("  {0}. {1,-16} {2}" -f $n, $m.Dir, $m.Why)
    }
}

if ($WhatIf) {
    Write-Host "`n-WhatIf set. Nothing was touched." -ForegroundColor Green
    exit 0
}

Write-Host ""
$answer = Read-Host "Type DESTROY to continue"
if ($answer -ne "DESTROY") { Write-Host "Cancelled."; exit 0 }

$started = Get-Date

# --- Databricks stage -----------------------------------------------------

function Invoke-Destroy {
    param([string]$Dir)

    $path = Join-Path $repoRoot ($Dir -replace "/", "\")
    if (-not (Test-Path $path)) {
        Write-Host "  skipped - $Dir is not in this checkout" -ForegroundColor DarkGray
        return
    }

    Push-Location $path
    try {
        Write-Host "`n--- $Dir" -ForegroundColor Cyan
        terraform init -input=false -upgrade=false | Out-Null

        $extra = @()
        if ($Dir -eq "infra/jumpbox") {
            $extra = @("-var", "allowed_source_ip=$AllowedSourceIp", "-var", "admin_password=$AdminPassword")
        }

        terraform destroy -auto-approve -input=false @extra
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  destroy FAILED for $Dir - stopping so the order is not broken" -ForegroundColor Red
            throw "terraform destroy failed in $Dir"
        }
    } finally {
        Pop-Location
    }
}

if ($Scope -ne "Azure") {
    Write-Host "`n### Databricks stage" -ForegroundColor Magenta
    Write-Host "These modules reach the workspace over a private endpoint. If this fails with"
    Write-Host "a name resolution error, you are not on the jumpbox." -ForegroundColor DarkGray
    foreach ($m in $databricksStage) { Invoke-Destroy -Dir $m.Dir }
}

# --- Azure stage ----------------------------------------------------------

if ($Scope -ne "Databricks") {
    Write-Host "`n### Azure stage" -ForegroundColor Magenta
    Write-Host "DO NOT RUN THIS ON THE JUMPBOX. It deletes the resource group the jumpbox" -ForegroundColor Yellow
    Write-Host "lives in, which means deleting the machine executing this line. Run the" -ForegroundColor Yellow
    Write-Host "Databricks stage from the jumpbox and this stage from your laptop." -ForegroundColor Yellow
    if ($env:COMPUTERNAME -eq "vm-jumpbox") {
        throw "Refusing to run the Azure stage on vm-jumpbox. Run it from your laptop."
    }

    if ($Fast) {
        # The tag is load-bearing. rg-terraform-state carries autodelete=false
        # precisely so that this query cannot reach it.
        $groups = az group list --query "[?tags.autodelete=='true'].name" --output tsv
        if ([string]::IsNullOrWhiteSpace($groups)) {
            Write-Host "  no resource groups tagged autodelete=true"
        } else {
            foreach ($g in ($groups -split "`n" | Where-Object { $_ })) {
                $name = $g.Trim()
                Write-Host "  deleting $name (no-wait)"
                az group delete --name $name --yes --no-wait --output none
            }
            Write-Host "`n  Deletions are running in the background. Watch them with:" -ForegroundColor Yellow
            Write-Host "    az group list --query `"[?tags.autodelete=='true'].{name:name,state:properties.provisioningState}`" -o table"
        }

        # State now describes resources that are on their way out. Emptying it
        # is the honest move: a state file that lies is worse than no state file,
        # because the next plan tries to UPDATE things that no longer exist.
        Write-Host "`n  Clearing state for the Azure modules..."
        foreach ($m in $azureStage) {
            az storage blob delete --account-name $StateAccount --container-name $StateContainer `
                --name $m.Key --auth-mode login --output none 2>$null
            Write-Host "    removed $($m.Key)"
        }
        Write-Host "  Blob versioning is on, so these are recoverable if you need them." -ForegroundColor DarkGray
    } else {
        foreach ($m in $azureStage) { Invoke-Destroy -Dir $m.Dir }
    }
}

# --- Report ---------------------------------------------------------------

$elapsed = (Get-Date) - $started
Write-Host "`n=== Done in $([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s ===" -ForegroundColor Green
Write-Host ""
Write-Host "Still standing, deliberately:"
Write-Host "  $StateResourceGroup    state, versioned, ~Rs 5/month"
Write-Host "  governance             budget + CI service principal, no running cost"
Write-Host ""
Write-Host "Check nothing was missed:" -ForegroundColor Cyan
Write-Host "  az group list --query `"[].{name:name,autodelete:tags.autodelete}`" -o table"
Write-Host ""
Write-Host "Databricks account objects are NOT in a resource group. If the Databricks"
Write-Host "stage was skipped, check the account console for leftover groups and"
Write-Host "service principals before rebuilding." -ForegroundColor DarkGray

<#
.SYNOPSIS
    Make a fresh jumpbox useful. Run this FIRST, inside the RDP session.

.DESCRIPTION
    The jumpbox is a bare Windows Server 2022 image. It has no Azure CLI, no
    Terraform, no Git and no copy of this repository - and it is the only machine
    that can reach the Databricks workspace, so everything left to build has to
    happen here.

    This installs the three tools, fetches the repo, and then proves the private
    networking actually works before you waste time on a Terraform run that was
    never going to connect.

    THE DNS CHECK AT THE END IS THE POINT. The workspace hostname is public and
    resolvable from anywhere; what differs is the ANSWER. From this machine it
    must resolve to a 10.10.1.x address in the transit VNet. If it comes back
    with a public address, the private endpoint or its DNS zone group is wrong,
    and every databricks-provider apply you try will hang and then fail with a
    timeout that says nothing about DNS.

.NOTES
    Windows Server blocks most browser downloads through IE Enhanced Security.
    Everything here uses Invoke-WebRequest instead, which is not subject to it.

.EXAMPLE
    # In an ELEVATED PowerShell on the jumpbox:
    Set-ExecutionPolicy -Scope Process Bypass -Force
    iwr https://raw.githubusercontent.com/<owner>/azure-lab-tf/main/infra/bootstrap/jumpbox-setup.ps1 -OutFile setup.ps1
    .\setup.ps1 -GitHubOwner <owner>
#>

[CmdletBinding()]
param(
    [string]$GitHubOwner = "bhanuprakashmolakathalla-onix",
    [string]$GitHubRepo = "azure-lab-tf",
    [string]$Branch = "main",
    [string]$TerraformVersion = "1.15.8",
    [string]$WorkDir = "C:\lab",
    [string]$WorkspaceName = "dbw-fashion",
    [string]$WorkspaceResourceGroup = "rg-lab01-foundation"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest is ~10x faster without it

Write-Host "=== Jumpbox setup ===" -ForegroundColor Cyan

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this in an ELEVATED PowerShell. Installing the Azure CLI needs it."
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$tools = Join-Path $WorkDir "tools"
New-Item -ItemType Directory -Force -Path $tools | Out-Null

# --- TLS ------------------------------------------------------------------
# Windows Server 2022 defaults are fine, but pinning this costs nothing and
# removes a class of "could not create SSL/TLS secure channel" that wastes an
# afternoon on older images.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Azure CLI ------------------------------------------------------------

Write-Host "`n[1/5] Azure CLI ..."
if (Get-Command az -ErrorAction SilentlyContinue) {
    Write-Host "      Already installed - skipping"
} else {
    $msi = Join-Path $env:TEMP "azure-cli.msi"
    Invoke-WebRequest -Uri "https://aka.ms/installazurecliwindowsx64" -OutFile $msi -UseBasicParsing
    Write-Host "      Installing (this takes a couple of minutes)..."
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait
    $azPath = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin"
    if (Test-Path $azPath) { $env:PATH = "$azPath;$env:PATH" }
    Write-Host "      Installed"
}

# --- Terraform ------------------------------------------------------------
#
# A zip into a folder on PATH, not an installer. Terraform is a single binary
# and pinning the version here is what keeps the jumpbox agreeing with CI.

Write-Host "`n[2/5] Terraform $TerraformVersion ..."
$tfExe = Join-Path $tools "terraform.exe"
if (Test-Path $tfExe) {
    Write-Host "      Already present - skipping"
} else {
    $zip = Join-Path $env:TEMP "terraform.zip"
    $url = "https://releases.hashicorp.com/terraform/$TerraformVersion/terraform_${TerraformVersion}_windows_amd64.zip"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tools -Force
    Write-Host "      Installed to $tools"
}
$env:PATH = "$tools;$env:PATH"

# Persist for future shells, so a reconnect does not start from nothing.
$machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
if ($machinePath -notlike "*$tools*") {
    [Environment]::SetEnvironmentVariable("PATH", "$machinePath;$tools", "Machine")
}

# --- The repository -------------------------------------------------------
#
# Downloaded as a zip rather than cloned. Git is a fourth install for the sake
# of a read-only checkout on a machine that is deleted tonight - the zip is one
# request and needs nothing.

Write-Host "`n[3/5] Repository ..."
$repoRoot = Join-Path $WorkDir $GitHubRepo
if (Test-Path $repoRoot) {
    Write-Host "      Already at $repoRoot - delete it first if you want a fresh copy"
} else {
    $zip = Join-Path $env:TEMP "repo.zip"
    Invoke-WebRequest -Uri "https://github.com/$GitHubOwner/$GitHubRepo/archive/refs/heads/$Branch.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $WorkDir -Force
    Rename-Item -Path (Join-Path $WorkDir "$GitHubRepo-$Branch") -NewName $GitHubRepo
    Write-Host "      Extracted to $repoRoot"
}

# --- Sign in --------------------------------------------------------------

Write-Host "`n[4/5] Azure sign-in ..."
$acct = az account show --output json 2>$null | ConvertFrom-Json
if ($acct) {
    Write-Host "      Already signed in as $($acct.user.name)"
} else {
    Write-Host "      A browser window will open. Sign in with the account that owns the lab." -ForegroundColor Yellow
    az login --output none
    $acct = az account show --output json | ConvertFrom-Json
    Write-Host "      Signed in as $($acct.user.name)"
}

# --- THE CHECK THAT MATTERS ----------------------------------------------

Write-Host "`n[5/5] Private DNS ..."
$wsUrl = az databricks workspace show --name $WorkspaceName --resource-group $WorkspaceResourceGroup `
    --query workspaceUrl --output tsv 2>$null

if ([string]::IsNullOrWhiteSpace($wsUrl)) {
    Write-Host "      Could not read the workspace URL. Has infra/workspace been applied?" -ForegroundColor Yellow
} else {
    Write-Host "      Workspace: $wsUrl"
    try {
        $answers = Resolve-DnsName -Name $wsUrl -Type A -ErrorAction Stop |
            Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress
    } catch {
        $answers = @()
    }

    if (-not $answers) {
        Write-Host "      NO ANSWER. The private DNS zone is not linked to this VNet." -ForegroundColor Red
    } elseif ($answers -match '^10\.') {
        Write-Host "      Resolves to $($answers -join ', ') - PRIVATE. The front-end endpoint is working." -ForegroundColor Green
    } else {
        Write-Host "      Resolves to $($answers -join ', ') - PUBLIC." -ForegroundColor Red
        Write-Host "      The private endpoint exists but its DNS zone group is not writing the A record," -ForegroundColor Red
        Write-Host "      or this VNet is not linked to privatelink.azuredatabricks.net in rg-lab01-transit." -ForegroundColor Red
        Write-Host "      Every databricks-provider apply will time out until that is fixed." -ForegroundColor Red
    }
}

# --- What next ------------------------------------------------------------

Write-Host "`n=== Ready ===" -ForegroundColor Green
Write-Host ""
Write-Host "Repo    : $repoRoot"
Write-Host "Tools   : $tools (on PATH for new shells too)"
Write-Host ""
Write-Host "Then, in order:" -ForegroundColor Cyan
Write-Host "  cd $repoRoot\data\catalog   ; terraform init ; terraform apply"
Write-Host "  cd ..\pipelines             ; terraform init ; terraform apply"
Write-Host "  # run the fashion-medallion job once from the Databricks UI, then:"
Write-Host "  cd ..\..\app                ; az acr build --registry <acr> --image fashion-app:v1 ."
Write-Host "  cd deploy                   ; terraform init ; terraform apply"
Write-Host ""
Write-Host "NOTE the two sites are IP-restricted. Pass the address of whatever machine" -ForegroundColor Yellow
Write-Host "will BROWSE them - your laptop, not this VM - as allowed_source_ips." -ForegroundColor Yellow

#Requires -Version 7.2
<#
.SYNOPSIS
    Removes the AVD security demo lab.

.DESCRIPTION
    Deletes both resource groups (the role assignments and the policy assignment on them go
    with them), removes the Entra ID sign-in log setting the lab created, and cleans up the
    local state files. The sessionhost's device object stays in Microsoft Entra ID; the script
    tells you which one to delete.

.EXAMPLE
    ./99-Remove-Environment.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    # Keep sending Entra ID sign-in logs, if 01-Deploy-Environment.ps1 connected them.
    [switch] $KeepSignInLogs
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'AvdSecurityDemo.psm1') -Force
$lab = Get-AvdDemoEnvironment
if (-not $lab) { throw 'No scripts/demo-environment.json found; nothing to remove.' }

if (-not (Get-AzContext)) { $null = Connect-AzAccount -Subscription $lab.subscriptionId }
$null = Set-AzContext -Subscription $lab.subscriptionId

$groups = @($lab.resourceGroups.hosts, $lab.resourceGroups.core)
if (-not $PSCmdlet.ShouldProcess(($groups -join ' and '), 'Remove the resource groups and everything in them')) { return }

foreach ($group in $groups) {
    if (Get-AzResourceGroup -Name $group -ErrorAction SilentlyContinue) {
        Write-Host "  Removing $group (a few minutes)..." -ForegroundColor Cyan
        $null = Remove-AzResourceGroup -Name $group -Force
    }
}

if ($lab.signInLogs -and -not $KeepSignInLogs) {
    $response = Invoke-AzRestMethod -Method DELETE -Path "/providers/microsoft.aadiam/diagnosticSettings/$($lab.prefix)-signins?api-version=2017-04-01"
    if ($response.StatusCode -in 200, 204) { Write-Host "  Entra ID diagnostic setting '$($lab.prefix)-signins' removed." }
    else { Write-Warning "Remove the Entra ID diagnostic setting '$($lab.prefix)-signins' by hand ($($response.StatusCode))." }
}

$baseline = Join-Path $PSScriptRoot ".demo-state/$($lab.hostPool.name).baseline.json"
Remove-Item -Path $baseline -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $PSScriptRoot 'demo-environment.json')

Write-Host "`nLab removed." -ForegroundColor Green
Write-Host "The device '$($lab.sessionHost.computerName)' is still in Microsoft Entra ID. Delete it in the Entra admin center under Devices." -ForegroundColor Yellow

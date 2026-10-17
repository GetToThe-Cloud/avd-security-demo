#Requires -Version 7.2
<#
.SYNOPSIS
    Go/no-go check for the AVD security demo lab.

.DESCRIPTION
    Reads scripts/demo-environment.json and checks what the demo needs: a sessionhost that
    is Available, the desktop and VM login roles for both users, the poweruser's
    misconfiguration for flip 1, the deny-public-IP policy and its age, the secured
    baseline RDP properties, and data arriving in Log Analytics.
    Ends with Show-AvdDemoState, the screen you open the demo with.

.EXAMPLE
    ./02-Test-Environment.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding()]
param(
    # Skip the Log Analytics queries.
    [switch] $SkipLogCheck
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'AvdSecurityDemo.psm1') -Force
$lab = Get-AvdDemoEnvironment
if (-not $lab) { throw 'No scripts/demo-environment.json found. Run 01-Deploy-Environment.ps1 first.' }

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string] $Check, [string] $Result, [string] $Detail) {
    $results.Add([pscustomobject]@{ Check = $Check; Result = $Result; Detail = $Detail })
    $color = switch ($Result) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ('  [{0,-4}] {1}: {2}' -f $Result, $Check, $Detail) -ForegroundColor $color
}

if (-not (Get-AzContext)) { $null = Connect-AzAccount -Subscription $lab.subscriptionId }
$null = Set-AzContext -Subscription $lab.subscriptionId
$core = $lab.resourceGroups.core
$hosts = $lab.resourceGroups.hosts
Write-Host "`nAVD security demo lab: go/no-go for $($lab.hostPool.name)`n" -ForegroundColor Cyan

# --- Sessionhost -----------------------------------------------------------------------------
$sessionHosts = @(Get-AzWvdSessionHost -ResourceGroupName $core -HostPoolName $lab.hostPool.name -ErrorAction SilentlyContinue)
if ($sessionHosts.Count -ne 1) {
    Add-Result -Check 'Sessionhosts' -Result 'WARN' -Detail "$($sessionHosts.Count) registered; the demo expects exactly one"
}
foreach ($sh in $sessionHosts) {
    $name = ($sh.Name -split '/')[-1]
    if ($sh.Status -eq 'Available' -and $sh.AllowNewSession) {
        Add-Result -Check 'Sessionhost' -Result 'OK' -Detail "$name is Available and accepts new sessions"
    }
    else {
        Add-Result -Check 'Sessionhost' -Result 'FAIL' -Detail "$name is $($sh.Status), new sessions allowed: $($sh.AllowNewSession)"
    }
}

# --- Users and roles --------------------------------------------------------------------------
$appGroupId = (Get-AzWvdApplicationGroup -ResourceGroupName $core -Name $lab.appGroup.name).Id
foreach ($upn in $lab.users.user, $lab.users.powerUser) {
    $user = Get-AzADUser -UserPrincipalName $upn
    if (-not $user) { Add-Result -Check $upn -Result 'FAIL' -Detail 'user not found'; continue }

    $desktop = Get-AzRoleAssignment -ObjectId $user.Id -RoleDefinitionName 'Desktop Virtualization User' -Scope $appGroupId -ErrorAction SilentlyContinue
    $login = Get-AzRoleAssignment -ObjectId $user.Id -RoleDefinitionName 'Virtual Machine User Login' -ResourceGroupName $hosts -ErrorAction SilentlyContinue
    if ($desktop -and $login) { Add-Result -Check $upn -Result 'OK' -Detail 'has the desktop and Virtual Machine User Login' }
    else { Add-Result -Check $upn -Result 'FAIL' -Detail "desktop: $([bool]$desktop), VM User Login: $([bool]$login). Rerun 01-Deploy-Environment.ps1" }
}
$powerUser = Get-AzADUser -UserPrincipalName $lab.users.powerUser
$adminLogin = Get-AzRoleAssignment -ObjectId $powerUser.Id -RoleDefinitionName 'Virtual Machine Administrator Login' -ResourceGroupName $hosts -ErrorAction SilentlyContinue |
    Where-Object { $_.Scope -like "*/resourceGroups/$hosts" }
if ($adminLogin) { Add-Result -Check 'Flip 1 misconfiguration' -Result 'OK' -Detail "$($lab.users.powerUser) has Virtual Machine Administrator Login" }
else { Add-Result -Check 'Flip 1 misconfiguration' -Result 'WARN' -Detail "not in place; run Grant-AvdDemoAdminLogin -SignInName $($lab.users.powerUser) a few minutes before the demo" }

# --- Policy --------------------------------------------------------------------------------------
$hostsScope = (Get-AzResourceGroup -Name $hosts).ResourceId
$policy = Get-AzPolicyAssignment -Name 'deny-public-ip-sessionhosts' -Scope $hostsScope -ErrorAction SilentlyContinue
if (-not $policy) {
    Add-Result -Check 'Deny public IP policy' -Result 'FAIL' -Detail "not assigned on $hosts; rerun 01-Deploy-Environment.ps1"
}
else {
    $created = $policy.SystemData.CreatedAt
    if ($created -and ((Get-Date).ToUniversalTime() - ([datetime]$created).ToUniversalTime()).TotalMinutes -lt 30) {
        Add-Result -Check 'Deny public IP policy' -Result 'WARN' -Detail 'assigned less than 30 minutes ago; it may not deny yet'
    }
    else {
        Add-Result -Check 'Deny public IP policy' -Result 'OK' -Detail "assigned on $hosts"
    }
}

# --- Baseline RDP properties ----------------------------------------------------------------------
$rdp = (Get-AzWvdHostPool -ResourceGroupName $core -Name $lab.hostPool.name).CustomRdpProperty
$open = @(
    if ($rdp -notmatch 'redirectclipboard:i:0') { 'clipboard' }
    if ($rdp -notmatch 'drivestoredirect:s:(;|$)') { 'drives' }
    if ($rdp -notmatch 'enablerdsaadauth:i:1') { 'SSO off' }
)
if ($open) { Add-Result -Check 'RDP properties' -Result 'WARN' -Detail "not at the baseline ($($open -join ', ')); run Reset-AvdDemo" }
else { Add-Result -Check 'RDP properties' -Result 'OK' -Detail 'secured baseline: SSO on, clipboard and drives off' }

# --- Log Analytics -------------------------------------------------------------------------------
if (-not $SkipLogCheck) {
    $queries = [ordered]@{
        'Host pool diagnostics' = 'WVDAgentHealthStatus | where TimeGenerated > ago(1h) | count'
        'Connections table'     = 'WVDConnections | where TimeGenerated > ago(7d) | count'
    }
    if ($lab.signInLogs) { $queries['Entra sign-in logs'] = 'SigninLogs | where TimeGenerated > ago(1d) | count' }
    foreach ($check in $queries.Keys) {
        try {
            $count = [int]((Invoke-AzOperationalInsightsQuery -WorkspaceId $lab.logAnalytics.customerId -Query $queries[$check]).Results | Select-Object -First 1).Count
        }
        catch { $count = 0 }
        if ($count -gt 0) { Add-Result -Check $check -Result 'OK' -Detail "$count rows" }
        else {
            $hint = switch ($check) {
                'Connections table' { 'no connections yet; connect once as each user before the demo' }
                'Entra sign-in logs' { 'nothing yet; sign-in logs take a few minutes to arrive' }
                default { 'no data yet; diagnostics can take 15 minutes after deployment' }
            }
            Add-Result -Check $check -Result 'WARN' -Detail $hint
        }
    }
    if (-not $lab.signInLogs) {
        Add-Result -Check 'Entra sign-in logs' -Result 'WARN' -Detail 'not connected by this lab; kql/avd-signins.kql needs SigninLogs in a workspace you can query'
    }
}

# --- Summary and the opening screen ---------------------------------------------------------------
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' })
Write-Host ''
if ($failed.Count) {
    Write-Host "No-go: $($failed.Count) check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'Go. This is the screen you open the demo with:' -ForegroundColor Green
Initialize-AvdDemo
Show-AvdDemoState

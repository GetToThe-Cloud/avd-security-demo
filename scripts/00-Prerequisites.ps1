#Requires -Version 7.2
<#
.SYNOPSIS
    One-time checks for the AVD security demo lab.

.DESCRIPTION
    Checks the PowerShell modules and the Bicep CLI, registers the resource providers,
    checks that the region can hold a host pool, that the VM size supports Trusted Launch
    and isn't restricted for your subscription, that the Windows 11 multi-session image is
    there, and that the vCPU quota covers one sessionhost.

    With -EnableEntraSso it also switches on Microsoft Entra authentication for RDP on the
    Windows Cloud Login service principal, which the host pool's enablerdsaadauth:i:1 needs.

.EXAMPLE
    ./00-Prerequisites.ps1 -SubscriptionId <id> -InstallMissingModules

.EXAMPLE
    ./00-Prerequisites.ps1 -SubscriptionId <id> -EnableEntraSso
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [string] $Region = 'westeurope',

    [string] $VmSize = 'Standard_D4ads_v5',

    [string] $ImageSku = 'win11-25h2-avd',

    [switch] $InstallMissingModules,

    [switch] $EnableEntraSso
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result([string] $Check, [string] $Result, [string] $Detail) {
    $results.Add([pscustomobject]@{ Check = $Check; Result = $Result; Detail = $Detail })
    $color = switch ($Result) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ('  [{0,-4}] {1}: {2}' -f $Result, $Check, $Detail) -ForegroundColor $color
}

Write-Host "`nAVD security demo lab: prerequisites`n" -ForegroundColor Cyan

# --- PowerShell modules ----------------------------------------------------------------
$modules = @(
    @{ Name = 'Az.Accounts'; MinimumVersion = '3.0.0' }
    @{ Name = 'Az.Resources'; MinimumVersion = '7.0.0' }
    @{ Name = 'Az.Compute'; MinimumVersion = '8.0.0' }
    @{ Name = 'Az.Network'; MinimumVersion = '7.0.0' }
    @{ Name = 'Az.DesktopVirtualization'; MinimumVersion = '4.0.0' }
    @{ Name = 'Az.OperationalInsights'; MinimumVersion = '3.2.0' }
)
foreach ($module in $modules) {
    $installed = Get-Module -ListAvailable -Name $module.Name | Sort-Object -Property Version -Descending | Select-Object -First 1
    if ($installed -and $installed.Version -ge [version]$module.MinimumVersion) {
        Add-Result -Check $module.Name -Result 'OK' -Detail "version $($installed.Version)"
        continue
    }
    if ($InstallMissingModules) {
        Install-Module -Name $module.Name -MinimumVersion $module.MinimumVersion -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        Add-Result -Check $module.Name -Result 'OK' -Detail 'installed'
    }
    else {
        Add-Result -Check $module.Name -Result 'FAIL' -Detail "needs $($module.MinimumVersion) or later; rerun with -InstallMissingModules"
    }
}

# --- Bicep CLI: New-AzSubscriptionDeployment calls it to compile main.bicep -------------
$bicep = Get-Command -Name bicep -ErrorAction SilentlyContinue
if ($bicep) {
    $bicepVersion = [regex]::Match((& $bicep.Source --version), '\d+\.\d+\.\d+').Value
    $result = if ([version]$bicepVersion -ge [version]'0.30.0') { 'OK' } else { 'WARN' }
    Add-Result -Check 'Bicep CLI' -Result $result -Detail "version $bicepVersion (0.30 or later recommended)"
}
else {
    Add-Result -Check 'Bicep CLI' -Result 'FAIL' -Detail 'not on PATH; install it from https://aka.ms/bicep-install (or az bicep install)'
}

# --- Azure context -----------------------------------------------------------------------
if (-not (Get-AzContext)) {
    $null = Connect-AzAccount -Subscription $SubscriptionId
}
$context = Set-AzContext -Subscription $SubscriptionId
Add-Result -Check 'Subscription' -Result 'OK' -Detail "$($context.Subscription.Name) ($SubscriptionId)"

# --- Resource providers ------------------------------------------------------------------
$providers = 'Microsoft.DesktopVirtualization', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.OperationalInsights', 'Microsoft.Insights', 'Microsoft.PolicyInsights'
foreach ($namespace in $providers) {
    $state = (Get-AzResourceProvider -ProviderNamespace $namespace | Select-Object -First 1).RegistrationState
    if ($state -ne 'Registered') {
        $null = Register-AzResourceProvider -ProviderNamespace $namespace
        $state = 'Registering'
    }
    Add-Result -Check "Provider $namespace" -Result 'OK' -Detail $state
}

# --- Region ------------------------------------------------------------------------------
$location = Get-AzLocation | Where-Object { $_.Location -eq $Region } | Select-Object -First 1
if (-not $location) { throw "Unknown region '$Region'." }
$hostPoolRegions = ((Get-AzResourceProvider -ProviderNamespace Microsoft.DesktopVirtualization).ResourceTypes |
    Where-Object { $_.ResourceTypeName -eq 'hostpools' }).Locations
if ($hostPoolRegions -contains $location.DisplayName) {
    Add-Result -Check 'AVD metadata region' -Result 'OK' -Detail $location.DisplayName
}
else {
    Add-Result -Check 'AVD metadata region' -Result 'FAIL' -Detail "$($location.DisplayName) can't hold host pools; pick another -Region"
}

# --- VM size: available, not restricted, Gen2 and Trusted Launch ----------------------------
$sku = Get-AzComputeResourceSku -Location $Region |
    Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VmSize } |
    Select-Object -First 1
if (-not $sku) {
    Add-Result -Check 'VM size' -Result 'FAIL' -Detail "$VmSize isn't offered in $Region"
}
else {
    $capability = @{}
    foreach ($c in $sku.Capabilities) { $capability[$c.Name] = $c.Value }
    $restricted = @($sku.Restrictions | Where-Object { $_.ReasonCode -eq 'NotAvailableForSubscription' })
    $gen2 = ($capability['HyperVGenerations'] -split ',') -contains 'V2'
    $trustedLaunch = $capability['TrustedLaunchDisabled'] -ne 'True'
    if ($restricted) {
        Add-Result -Check 'VM size' -Result 'FAIL' -Detail "$VmSize is restricted for this subscription in $Region; pick another -VmSize"
    }
    elseif (-not ($gen2 -and $trustedLaunch)) {
        Add-Result -Check 'VM size' -Result 'FAIL' -Detail "$VmSize doesn't support Gen2 with Trusted Launch"
    }
    else {
        Add-Result -Check 'VM size' -Result 'OK' -Detail "$VmSize ($($sku.Family)), Gen2, Trusted Launch"
    }

    # --- Quota ---------------------------------------------------------------------------
    $vcpus = [int]$capability['vCPUs']
    $usage = Get-AzVMUsage -Location $Region
    foreach ($quotaName in @($sku.Family, 'cores')) {
        $quota = $usage | Where-Object { $_.Name.Value -eq $quotaName } | Select-Object -First 1
        if (-not $quota) { continue }
        $free = $quota.Limit - $quota.CurrentValue
        $label = if ($quotaName -eq 'cores') { 'Regional vCPU quota' } else { "$quotaName quota" }
        $result = if ($free -ge $vcpus) { 'OK' } else { 'FAIL' }
        Add-Result -Check $label -Result $result -Detail "$free of $($quota.Limit) free, the lab needs $vcpus"
    }
}

# --- Image -------------------------------------------------------------------------------
$imageSkus = @(Get-AzVMImageSku -Location $Region -PublisherName 'MicrosoftWindowsDesktop' -Offer 'windows-11' | Select-Object -ExpandProperty Skus)
if ($imageSkus -contains $ImageSku) {
    Add-Result -Check 'Image' -Result 'OK' -Detail "MicrosoftWindowsDesktop/windows-11/$ImageSku"
}
else {
    $avdSkus = ($imageSkus | Where-Object { $_ -like '*-avd' }) -join ', '
    Add-Result -Check 'Image' -Result 'FAIL' -Detail "$ImageSku not found in $Region. Multi-session SKUs here: $avdSkus"
}

# --- Microsoft Entra authentication for RDP (single sign-on) ----------------------------------
$windowsCloudLoginAppId = '270efc09-cd0d-444b-a71f-39af4910ec45'
if ($EnableEntraSso) {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
        Write-Host '  Installing Microsoft.Graph.Applications for -EnableEntraSso...'
        Install-Module -Name Microsoft.Graph.Applications -Scope CurrentUser -Repository PSGallery -Force
    }
    Import-Module Microsoft.Graph.Applications # brings the matching Microsoft.Graph.Authentication along
    try {
        Connect-MgGraph -Scopes 'Application.Read.All', 'Application-RemoteDesktopConfig.ReadWrite.All' -NoWelcome -ErrorAction Stop
    }
    catch {
        throw "Microsoft Graph sign-in failed or was canceled. Rerun with -EnableEntraSso and complete the sign-in. $($_.Exception.Message)"
    }
    $wclSp = Get-MgServicePrincipal -Filter "AppId eq '$windowsCloudLoginAppId'"
    $config = Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $wclSp.Id -ErrorAction SilentlyContinue
    if (-not ($config -and $config.IsRemoteDesktopProtocolEnabled)) {
        Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $wclSp.Id -IsRemoteDesktopProtocolEnabled
        Add-Result -Check 'Entra auth for RDP' -Result 'OK' -Detail 'enabled on Windows Cloud Login'
    }
    else {
        Add-Result -Check 'Entra auth for RDP' -Result 'OK' -Detail 'already enabled on Windows Cloud Login'
    }
}
else {
    Add-Result -Check 'Entra auth for RDP' -Result 'WARN' -Detail 'not checked. The host pool uses enablerdsaadauth:i:1; rerun with -EnableEntraSso if SSO is not set up in this tenant yet'
}

# --- Summary -------------------------------------------------------------------------------
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' })
Write-Host ''
if ($failed.Count) {
    Write-Host "$($failed.Count) check(s) failed. Fix them before you deploy." -ForegroundColor Red
    exit 1
}
Write-Host 'All set. Next: ./01-Deploy-Environment.ps1' -ForegroundColor Green

#Requires -Version 7.2
<#
.SYNOPSIS
    Builds the AVD security demo lab from zero.

.DESCRIPTION
    Runs bicep/main.bicep twice at subscription scope and does the steps in between:
      1. phase 'core': network with a NAT gateway, Log Analytics, the host pool with the
         secured baseline RDP properties, the desktop and its assignment, diagnostics, and
         on the hosts resource group the VM User Login roles and the deny-public-IP policy
      2. a registration token, valid for two hours
      3. phase 'sessionhost': one Trusted Launch, Entra-joined Windows 11 multi-session VM
         that registers itself with the AVD agent
      4. waits until the host is Available, restarts it once as Microsoft documents, and
         removes the registration token again
      5. gives the poweruser Virtual Machine Administrator Login: flip 1's misconfiguration
      6. with -ConnectEntraSignInLogs, sends Entra ID sign-in logs to the lab's workspace
    The outputs land in scripts/demo-environment.json, which the other scripts, the module
    and Start-AvdDemo.ps1 read.

    Safe to run again: the core phase resets the RDP properties to the baseline, and the
    sessionhost phase is skipped when the host is already registered.

.EXAMPLE
    ./01-Deploy-Environment.ps1 -SubscriptionId <id> -UserUpn avd.user@contoso.com -PowerUserUpn avd.poweruser@contoso.com

.EXAMPLE
    ./01-Deploy-Environment.ps1 -SubscriptionId <id> -UserUpn avd.user@contoso.com -PowerUserUpn avd.poweruser@contoso.com -ConnectEntraSignInLogs
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    # The standard demo user: Virtual Machine User Login only.
    [Parameter(Mandatory)]
    [string] $UserUpn,

    # The demo's poweruser: also gets Virtual Machine Administrator Login, the misconfiguration flip 1 removes.
    [Parameter(Mandatory)]
    [string] $PowerUserUpn,

    [string] $Region = 'westeurope',

    [ValidatePattern('^[a-z0-9]{3,8}$')]
    [string] $Prefix = 'avdsec',

    [string] $VmSize = 'Standard_D4as_v6',

    [string] $ImageSku = 'win11-25h2-avd',

    # Send Entra ID sign-in logs to the lab's Log Analytics workspace (tenant-wide setting;
    # needs Security Administrator or Global Administrator and Entra ID P1 or P2).
    [switch] $ConnectEntraSignInLogs,

    # Leave the poweruser a standard user.
    [switch] $SkipAdminLoginMisconfiguration,

    # Local admin password for the host. A random one is generated when you leave it out;
    # it isn't stored anywhere, you sign in with Entra ID.
    [securestring] $AdminPassword
)

$ErrorActionPreference = 'Stop'
$templateFile = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../bicep/main.bicep')).Path
$environmentFile = Join-Path -Path $PSScriptRoot -ChildPath 'demo-environment.json'
$vmAdminLoginRole = 'Virtual Machine Administrator Login'

function Get-DemoPassword {
    # Builds the SecureString one character at a time, so the password never exists as a plain string.
    $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%*-_=+'
    $all = -join $sets
    $chars = foreach ($set in $sets) { $set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)] }
    $chars += 1..20 | ForEach-Object { $all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)] }
    $secure = [securestring]::new()
    foreach ($char in ($chars | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(1000) })) {
        $secure.AppendChar($char)
    }
    $secure.MakeReadOnly()
    $secure
}

function Invoke-LabDeployment {
    param([string] $Phase, [hashtable] $Parameters)
    $deployment = @{
        Name         = "avdsec-$Phase-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Location     = $Region
        TemplateFile = $templateFile
        phase        = $Phase
    } + $Parameters
    $result = New-AzSubscriptionDeployment @deployment
    if ($result.ProvisioningState -ne 'Succeeded') {
        throw "Deployment $($deployment.Name) ended in state $($result.ProvisioningState)."
    }
    $result
}

function Wait-SessionHostAvailable {
    param([string] $ResourceGroupName, [string] $HostPoolName, [int] $TimeoutMinutes = 30)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $hosts = @(Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ErrorAction SilentlyContinue)
        $status = if ($hosts) { ($hosts | ForEach-Object { '{0}: {1}' -f ($_.Name -split '/')[-1], $_.Status }) -join ', ' } else { 'not registered yet' }
        Write-Host "    $(Get-Date -Format 'HH:mm:ss')  $status"
        if ($hosts -and -not ($hosts | Where-Object Status -ne 'Available')) { return $true }
        Start-Sleep -Seconds 30
    } while ((Get-Date) -lt $deadline)
    $false
}

# --- Context -----------------------------------------------------------------------------
if (-not (Get-AzContext)) { $null = Connect-AzAccount -Subscription $SubscriptionId }
$null = Set-AzContext -Subscription $SubscriptionId
Write-Host "`nBuilding the AVD security demo lab in $((Get-AzContext).Subscription.Name)`n" -ForegroundColor Cyan

# --- Demo users --------------------------------------------------------------------------
$users = [ordered]@{}
foreach ($upn in $UserUpn, $PowerUserUpn) {
    $user = Get-AzADUser -UserPrincipalName $upn
    if (-not $user) { throw "User $upn not found in this tenant." }
    $users[$upn] = $user.Id
    Write-Host "  Demo user: $upn ($($user.Id))"
}

# --- Image -------------------------------------------------------------------------------
$imageSkus = @(Get-AzVMImageSku -Location $Region -PublisherName 'MicrosoftWindowsDesktop' -Offer 'windows-11' | Select-Object -ExpandProperty Skus)
if ($imageSkus -notcontains $ImageSku) {
    throw "Image SKU $ImageSku isn't available in $Region. Run 00-Prerequisites.ps1 to see the options."
}

$templateParameters = @{
    prefix        = $Prefix
    region        = $Region
    userObjectIds = [string[]]@($users.Values)
    vmSize        = $VmSize
    imageSku      = $ImageSku
}
$resourceGroupCore = "rg-$Prefix-core"
$resourceGroupHosts = "rg-$Prefix-hosts"
$hostPoolName = "vdpool-$Prefix"

# --- Phase 1: core -----------------------------------------------------------------------
Write-Host "`n  Phase 'core': network, monitoring, host pool, roles and policy (a few minutes)..." -ForegroundColor Cyan
$null = Invoke-LabDeployment -Phase 'core' -Parameters $templateParameters

# --- Phase 2: the sessionhost --------------------------------------------------------------
$registered = @(Get-AzWvdSessionHost -ResourceGroupName $resourceGroupCore -HostPoolName $hostPoolName -ErrorAction SilentlyContinue)
if ($registered) {
    Write-Host "`n  The sessionhost is already registered; skipping phase 'sessionhost'." -ForegroundColor DarkGray
}
else {
    Write-Host "`n  Registration token, valid for two hours..." -ForegroundColor Cyan
    $null = New-AzWvdRegistrationInfo -ResourceGroupName $resourceGroupCore -HostPoolName $hostPoolName `
        -ExpirationTime (Get-Date).ToUniversalTime().AddHours(2).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    $token = [System.Net.NetworkCredential]::new('', (Get-AzWvdHostPoolRegistrationToken -ResourceGroupName $resourceGroupCore -HostPoolName $hostPoolName).Token).SecurePassword

    if (-not $AdminPassword) { $AdminPassword = Get-DemoPassword }
    Write-Host "`n  Phase 'sessionhost': Trusted Launch VM, Entra join, AVD agent (10 to 15 minutes)..." -ForegroundColor Cyan
    try {
        $null = Invoke-LabDeployment -Phase 'sessionhost' -Parameters ($templateParameters + @{
                vmAdminPassword   = $AdminPassword
                registrationToken = $token
            })

        Write-Host "`n  Waiting for the host to report Available..." -ForegroundColor Cyan
        if (-not (Wait-SessionHostAvailable -ResourceGroupName $resourceGroupCore -HostPoolName $hostPoolName)) {
            throw 'The sessionhost did not become Available in 30 minutes. Check C:\AVDAgent\*.log on the VM through Run Command.'
        }

        # Microsoft's registration steps end with a restart once the host is Available.
        Write-Host "`n  Restarting the host once, then waiting for it again..." -ForegroundColor Cyan
        $null = Restart-AzVM -ResourceGroupName $resourceGroupHosts -Name "vm-$Prefix-sh0"
        Start-Sleep -Seconds 60
        if (-not (Wait-SessionHostAvailable -ResourceGroupName $resourceGroupCore -HostPoolName $hostPoolName)) {
            Write-Warning 'The host is not Available yet after the restart. Give it a few minutes and run 02-Test-Environment.ps1.'
        }
    }
    finally {
        # The token is a credential that lets any machine join the pool. Don't leave it lying around.
        Remove-AzWvdRegistrationInfo -ResourceGroupName $resourceGroupCore -HostPoolName $hostPoolName
        Write-Host '  Registration token removed.' -ForegroundColor DarkGray
    }
}

# --- Flip 1's misconfiguration ---------------------------------------------------------------
$powerUserId = $users[$PowerUserUpn]
if (-not $SkipAdminLoginMisconfiguration) {
    $existing = Get-AzRoleAssignment -ObjectId $powerUserId -RoleDefinitionName $vmAdminLoginRole -ResourceGroupName $resourceGroupHosts -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -like "*/resourceGroups/$resourceGroupHosts" }
    if (-not $existing) {
        $null = New-AzRoleAssignment -ObjectId $powerUserId -RoleDefinitionName $vmAdminLoginRole -ResourceGroupName $resourceGroupHosts
    }
    Write-Host "`n  $PowerUserUpn has $vmAdminLoginRole on ${resourceGroupHosts}: the misconfiguration for flip 1." -ForegroundColor Yellow
}

# --- Entra ID sign-in logs to the lab workspace (optional, tenant-wide) ------------------------
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $resourceGroupCore -Name "log-$Prefix"
if ($ConnectEntraSignInLogs) {
    $body = @{
        properties = @{
            workspaceId = $workspace.ResourceId
            logs        = @(
                @{ category = 'SignInLogs'; enabled = $true }
                @{ category = 'NonInteractiveUserSignInLogs'; enabled = $true }
            )
        }
    } | ConvertTo-Json -Depth 5
    $response = Invoke-AzRestMethod -Method PUT -Path "/providers/microsoft.aadiam/diagnosticSettings/$Prefix-signins?api-version=2017-04-01" -Payload $body
    if ($response.StatusCode -in 200, 201) {
        Write-Host "`n  Entra ID sign-in logs now flow to log-$Prefix (diagnostic setting '$Prefix-signins')." -ForegroundColor Green
    }
    else {
        Write-Warning "Could not connect the sign-in logs ($($response.StatusCode)). Do it in Entra ID > Diagnostic settings, or ask a Security Administrator. $($response.Content)"
    }
}

# --- Friendly desktop name and a launch link for the web client ------------------------------
$desktop = Update-AzWvdDesktop -ResourceGroupName $resourceGroupCore -ApplicationGroupName "vdag-$Prefix-desktop" -Name 'SessionDesktop' -FriendlyName 'AVD security demo'
$avdWorkspace = Get-AzWvdWorkspace -ResourceGroupName $resourceGroupCore -Name "vdws-$Prefix"
$launchUrl = "https://windows.cloud.microsoft/webclient/avd/$($avdWorkspace.ObjectId)/$($desktop.ObjectId)"

# --- Save the environment for the other scripts ------------------------------------------------
$environment = [ordered]@{
    subscriptionId  = $SubscriptionId
    deployedAt      = (Get-Date).ToUniversalTime().ToString('o')
    prefix          = $Prefix
    region          = $Region
    resourceGroups  = [ordered]@{ core = $resourceGroupCore; hosts = $resourceGroupHosts }
    hostPool        = [ordered]@{ name = $hostPoolName }
    appGroup        = [ordered]@{ name = "vdag-$Prefix-desktop" }
    workspace       = [ordered]@{ name = "vdws-$Prefix" }
    logAnalytics    = [ordered]@{ name = "log-$Prefix"; id = $workspace.ResourceId; customerId = $workspace.CustomerId.ToString() }
    sessionHost     = [ordered]@{ vmName = "vm-$Prefix-sh0"; computerName = "$Prefix-sh0" }
    users           = [ordered]@{ user = $UserUpn; powerUser = $PowerUserUpn }
    signInLogs      = [bool]$ConnectEntraSignInLogs
    launchUrl       = $launchUrl
}
$environment | ConvertTo-Json -Depth 8 | Set-Content -Path $environmentFile -Encoding utf8

Write-Host "`nDone. Environment saved to $environmentFile." -ForegroundColor Green
Write-Host @"

Next:
  ./02-Test-Environment.ps1          go/no-go check
  Import-Module ./AvdSecurityDemo.psm1 -Force; Initialize-AvdDemo; Show-AvdDemoState
  ./Start-AvdDemo.ps1 -Watermark     the demo itself

Web client link for the demo users (add #loginHint=<upn> to skip the account picker):
  $launchUrl
"@

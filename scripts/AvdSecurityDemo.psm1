#Requires -Version 7.2
<#
    AvdSecurityDemo.psm1
    Demo helpers for "Azure Virtual Desktop | Securing Your Environment"
    gettothe.cloud - Alex ter Neuzen

    Shows what is implemented on one AVD host pool and flips individual settings live,
    so the audience sees what happens when you change setting X.

    Built for a LAB or DEMO host pool. Every change is reversible with Reset-AvdDemo.

    Quick start
        Import-Module ./AvdSecurityDemo.psm1 -Force
        Initialize-AvdDemo     # the lab from 01-Deploy-Environment.ps1, or:
        Initialize-AvdDemo -SubscriptionId <id> -ResourceGroupName rg-avd-demo -HostPoolName hp-avd-demo
        Show-AvdDemoState

    Needs: Az.Accounts, Az.DesktopVirtualization, Az.Compute, Az.Network, Az.Resources
           (Az.Monitor optional, for the diagnostic settings check)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console output for a presenter at a terminal, not objects for a pipeline')]
param()

$script:Demo = $null

$script:RoleUser             = 'Virtual Machine User Login'
$script:RoleAdmin            = 'Virtual Machine Administrator Login'
$script:NotAllowedTypesDefId = '/providers/Microsoft.Authorization/policyDefinitions/6c112d4e-5bc7-47ae-a041-ea2d9dccd749'
$script:TsPolicyValues       = @(
    'fDisableCdm', 'SCClipLevel', 'CSClipLevel',
    'fEnableWatermarking', 'WatermarkingOpacity', 'WatermarkingQrScale', 'WatermarkingWidthFactor', 'WatermarkingHeightFactor'
)

#region Output helpers ---------------------------------------------------------------

function Write-DemoHeader {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Write-DemoSection {
    param([string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor White
    Write-Host ('  ' + ('-' * ($Text.Length))) -ForegroundColor DarkGray
}

function Write-DemoLine {
    param(
        [ValidateSet('Ok', 'Fail', 'Warn', 'Info')][string]$Status,
        [string]$Text,
        [string]$Step
    )
    $tag, $color = switch ($Status) {
        'Ok'   { '[ OK ]', 'Green' }
        'Fail' { '[ !! ]', 'Red' }
        'Warn' { '[ ?? ]', 'Yellow' }
        'Info' { '[ .. ]', 'Gray' }
    }
    $stepText = if ($Step) { "step $Step" } else { '' }
    Write-Host ('  {0}  {1,-62} {2}' -f $tag, $Text, $stepText) -ForegroundColor $color
}

#endregion

#region Internal helpers ---------------------------------------------------------------

function Get-DemoContext {
    if (-not $script:Demo) {
        throw 'Run Initialize-AvdDemo first.'
    }
    $script:Demo
}

function ConvertFrom-RdpPropertyString {
    # "a:i:1;b:s:*;" -> ordered dictionary keyed on the lower-case property name, value = full entry
    param([string]$RdpString)
    $props = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($RdpString)) { return $props }
    foreach ($entry in ($RdpString -split ';')) {
        $entry = $entry.Trim()
        if (-not $entry) { continue }
        $name = ($entry -split ':', 2)[0].Trim().ToLowerInvariant()
        $props[$name] = $entry
    }
    $props
}

function ConvertTo-RdpPropertyString {
    param([System.Collections.IDictionary]$Properties)
    (@($Properties.Values) -join ';') + ';'
}

function Get-RdpValue {
    # Returns the value part of "name:type:value", or $null when the property is not set
    param([System.Collections.IDictionary]$Properties, [string]$Name)
    $entry = $Properties[$Name.ToLowerInvariant()]
    if ($null -eq $entry) { return $null }
    ($entry -split ':', 3)[2]
}

function Get-DemoSessionHostVm {
    $ctx = Get-DemoContext
    foreach ($sh in Get-AzWvdSessionHost -HostPoolName $ctx.HostPoolName -ResourceGroupName $ctx.ResourceGroupName) {
        $parts = $sh.ResourceId -split '/'
        [pscustomobject]@{
            SessionHost     = ($sh.Name -split '/')[-1]
            Status          = $sh.Status
            AllowNewSession = $sh.AllowNewSession
            VmResourceGroup = $parts[4]
            VmName          = $parts[8]
            ResourceId      = $sh.ResourceId
        }
    }
}

function Invoke-DemoHostScript {
    # Runs a PowerShell script on the sessionhosts through Run Command and returns the output
    param(
        [Parameter(Mandatory)][string]$Script,
        [string[]]$VmName
    )
    $hosts = @(Get-DemoSessionHostVm)
    if ($VmName) { $hosts = @($hosts | Where-Object VmName -in $VmName) }
    if (-not $hosts) { throw 'No sessionhosts found to run on.' }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('avd-demo-{0}.ps1' -f [guid]::NewGuid())
    Set-Content -Path $tmp -Value $Script -Encoding utf8
    try {
        foreach ($h in $hosts) {
            Write-Host "  -> $($h.VmName): Run Command on the host (30 to 60 seconds)" -ForegroundColor DarkGray
            $r = Invoke-AzVMRunCommand -ResourceGroupName $h.VmResourceGroup -VMName $h.VmName `
                    -CommandId 'RunPowerShellScript' -ScriptPath $tmp
            [pscustomobject]@{
                VmName = $h.VmName
                Output = ($r.Value | Where-Object Code -like '*StdOut*' | Select-Object -ExpandProperty Message) -join "`n"
                Error  = ($r.Value | Where-Object Code -like '*StdErr*' | Select-Object -ExpandProperty Message) -join "`n"
            }
        }
    }
    finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }
}

function Write-HostScriptResult {
    param($Result)
    foreach ($r in $Result) {
        Write-Host "  $($r.VmName)" -ForegroundColor White
        if ($r.Output) { $r.Output.Trim() -split "`n" | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray } }
        if ($r.Error)  { $r.Error.Trim()  -split "`n" | ForEach-Object { Write-Host "     $_" -ForegroundColor Red } }
    }
}

#endregion

#region Setup --------------------------------------------------------------------------

function Get-AvdDemoEnvironment {
    <#
    .SYNOPSIS
        Reads scripts/demo-environment.json, written by 01-Deploy-Environment.ps1.
        Returns nothing when the lab was not deployed with this repo.
    #>
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot 'demo-environment.json'))
    if (Test-Path -Path $Path) {
        Get-Content -Path $Path -Raw | ConvertFrom-Json
    }
}

function Initialize-AvdDemo {
    <#
    .SYNOPSIS
        Points the module at the demo host pool and saves the baseline RDP properties once.
    .DESCRIPTION
        Without parameters it uses the lab from scripts/demo-environment.json, written by
        01-Deploy-Environment.ps1. Pass the three values to point it at a host pool of your own.
    #>
    [CmdletBinding()]
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$HostPoolName,
        [string]$StatePath = (Join-Path $PSScriptRoot '.demo-state')
    )

    $environment = Get-AvdDemoEnvironment
    if ($environment) {
        if (-not $SubscriptionId)    { $SubscriptionId    = $environment.subscriptionId }
        if (-not $ResourceGroupName) { $ResourceGroupName = $environment.resourceGroups.core }
        if (-not $HostPoolName)      { $HostPoolName      = $environment.hostPool.name }
    }
    if (-not ($SubscriptionId -and $ResourceGroupName -and $HostPoolName)) {
        throw 'Pass -SubscriptionId, -ResourceGroupName and -HostPoolName, or deploy the lab with 01-Deploy-Environment.ps1 first.'
    }

    $null = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
    $hp = Get-AzWvdHostPool -Name $HostPoolName -ResourceGroupName $ResourceGroupName -ErrorAction Stop

    $script:Demo = [pscustomobject]@{
        SubscriptionId    = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        HostPoolName      = $HostPoolName
        HostPoolId        = $hp.Id
        BaselineFile      = Join-Path $StatePath "$HostPoolName.baseline.json"
        VmResourceGroups  = @()
    }
    $script:Demo.VmResourceGroups = @(Get-DemoSessionHostVm | Select-Object -ExpandProperty VmResourceGroup -Unique)

    if (-not (Test-Path $StatePath)) { $null = New-Item -Path $StatePath -ItemType Directory -Force }
    if (-not (Test-Path $script:Demo.BaselineFile)) {
        @{ CustomRdpProperty = $hp.CustomRdpProperty; SavedAt = (Get-Date).ToString('o') } |
            ConvertTo-Json | Set-Content -Path $script:Demo.BaselineFile -Encoding utf8
        Write-Host "  Baseline RDP properties saved to $($script:Demo.BaselineFile)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Using existing baseline in $($script:Demo.BaselineFile)" -ForegroundColor DarkGray
    }

    $count = @(Get-DemoSessionHostVm).Count
    Write-Host "  Demo context ready: $HostPoolName, $count sessionhost(s) in $($script:Demo.VmResourceGroups -join ', ')" -ForegroundColor Cyan
    if ($count -ne 1) {
        Write-Host '  Tip: a single sessionhost (or the rest in drain mode) keeps the demo predictable.' -ForegroundColor Yellow
    }
}

#endregion

#region Show what is built --------------------------------------------------------------

function Show-AvdDemoState {
    <#
    .SYNOPSIS
        One-screen posture check of the demo host pool, mapped to the attack chain.
    #>
    [CmdletBinding()]
    param()
    $ctx = Get-DemoContext
    $hp  = Get-AzWvdHostPool -Name $ctx.HostPoolName -ResourceGroupName $ctx.ResourceGroupName
    $rdp = ConvertFrom-RdpPropertyString $hp.CustomRdpProperty

    Write-DemoHeader "AVD posture: $($hp.Name)  ($($hp.HostPoolType), $($hp.LoadBalancerType))"

    # --- Identity -------------------------------------------------------------------
    Write-DemoSection 'Identity'
    $sso = Get-RdpValue $rdp 'enablerdsaadauth'
    if ($sso -eq '1') { Write-DemoLine Ok 'Entra single sign-on on the host pool (enablerdsaadauth:i:1)' -Step 2 }
    else              { Write-DemoLine Fail "Entra single sign-on not set (enablerdsaadauth = $sso)" -Step 2 }

    foreach ($rg in $ctx.VmResourceGroups) {
        $assignments = @(Get-AzRoleAssignment -ResourceGroupName $rg |
                         Where-Object RoleDefinitionName -in @($script:RoleUser, $script:RoleAdmin))
        if (-not $assignments) { Write-DemoLine Warn "No VM login role assignments found for $rg" -Step 4 }
        foreach ($a in $assignments) {
            $who     = if ($a.SignInName) { $a.SignInName } else { $a.DisplayName }
            $atSub   = $a.Scope -match '^/subscriptions/[^/]+$'
            $scopeTx = if ($atSub) { 'subscription scope' } else { 'resource group scope' }
            if ($a.RoleDefinitionName -eq $script:RoleAdmin) {
                Write-DemoLine Fail "$who has VM Administrator Login ($scopeTx)" -Step 4
            }
            elseif ($atSub) {
                Write-DemoLine Warn "$who has VM User Login at subscription scope" -Step 4
            }
            else {
                Write-DemoLine Ok "$who has VM User Login ($scopeTx)" -Step 4
            }
        }
    }

    # --- Sessionhosts ---------------------------------------------------------------
    Write-DemoSection 'Sessionhosts'
    foreach ($h in Get-DemoSessionHostVm) {
        $vm  = Get-AzVM -ResourceGroupName $h.VmResourceGroup -Name $h.VmName
        $sec = $vm.SecurityProfile
        $tl   = $sec -and $sec.SecurityType -eq 'TrustedLaunch'
        $sb   = $sec -and $sec.UefiSettings -and $sec.UefiSettings.SecureBootEnabled
        $vtpm = $sec -and $sec.UefiSettings -and $sec.UefiSettings.VTpmEnabled
        if ($tl -and $sb -and $vtpm) { Write-DemoLine Ok "$($h.VmName): Trusted Launch, Secure Boot, vTPM" -Step 3 }
        else { Write-DemoLine Fail "$($h.VmName): TrustedLaunch=$tl SecureBoot=$sb vTPM=$vtpm" -Step 3 }

        $publicIps = foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
            $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
            $nic.IpConfigurations | Where-Object { $_.PublicIpAddress } | ForEach-Object { $_.PublicIpAddress.Id }
        }
        if ($publicIps) { Write-DemoLine Fail "$($h.VmName): public IP attached" -Step 6 }
        else            { Write-DemoLine Ok   "$($h.VmName): no public IP" -Step 6 }

        $img = $vm.StorageProfile.ImageReference
        if ($img.Id) {
            $p = $img.Id -split '/'
            $i = [Array]::IndexOf($p, 'images')
            $imgName = if ($i -ge 0) { $p[$i + 1] } else { $p[-1] }
            $imgVer  = if ($img.ExactVersion) { $img.ExactVersion } elseif ($p -contains 'versions') { $p[-1] } else { 'latest' }
            Write-DemoLine Info "$($h.VmName): image $imgName $imgVer (gallery)" -Step 3
        }
        else {
            Write-DemoLine Info "$($h.VmName): image $($img.Offer)/$($img.Sku) $($img.ExactVersion) (marketplace)" -Step 3
        }
        Write-DemoLine Info "$($h.VmName): status $($h.Status), new sessions allowed: $($h.AllowNewSession)"
    }

    # --- Session and data -----------------------------------------------------------
    Write-DemoSection 'Session and data (host pool RDP properties = configuration)'
    $clip  = Get-RdpValue $rdp 'redirectclipboard'
    $drive = Get-RdpValue $rdp 'drivestoredirect'
    $print = Get-RdpValue $rdp 'redirectprinters'
    $usb   = Get-RdpValue $rdp 'usbdevicestoredirect'
    if ($clip -eq '0') { Write-DemoLine Ok 'Clipboard redirection off (redirectclipboard:i:0)' -Step 5 }
    else               { Write-DemoLine Fail "Clipboard redirection on (redirectclipboard = $clip)" -Step 5 }
    if ($null -ne $drive -and $drive -eq '') { Write-DemoLine Ok 'Drive redirection off (drivestoredirect:s:)' -Step 5 }
    else { Write-DemoLine Fail "Drive redirection on (drivestoredirect = '$drive')" -Step 5 }
    if ($print -eq '0') { Write-DemoLine Ok 'Printer redirection off (redirectprinters:i:0)' -Step 5 }
    else                { Write-DemoLine Warn "Printer redirection on (redirectprinters = $print)" -Step 5 }
    if ($null -ne $usb -and $usb -eq '') { Write-DemoLine Ok 'USB redirection off (usbdevicestoredirect:s:)' -Step 5 }
    else { Write-DemoLine Warn "USB redirection not explicitly off (usbdevicestoredirect = '$usb')" -Step 5 }

    # --- Network --------------------------------------------------------------------
    Write-DemoSection 'Network'
    foreach ($rg in $ctx.VmResourceGroups) {
        $scope = (Get-AzResourceGroup -Name $rg).ResourceId
        $denyPip = Get-AzPolicyAssignment -Scope $scope -ErrorAction SilentlyContinue | Where-Object {
            $defId = if ($_.PolicyDefinitionId) { $_.PolicyDefinitionId } else { $_.Properties.PolicyDefinitionId }
            $defId -eq $script:NotAllowedTypesDefId
        }
        if ($denyPip) { Write-DemoLine Ok "Policy 'Not allowed resource types' assigned on $rg" -Step 6 }
        else          { Write-DemoLine Warn "No 'Not allowed resource types' assignment on $rg" -Step 6 }
    }

    # --- Detection ------------------------------------------------------------------
    Write-DemoSection 'Detection'
    if (Get-Command Get-AzDiagnosticSetting -ErrorAction SilentlyContinue) {
        $diag = @(Get-AzDiagnosticSetting -ResourceId $ctx.HostPoolId -ErrorAction SilentlyContinue)
        if ($diag) { Write-DemoLine Ok "Host pool diagnostics: $($diag.Name -join ', ')" -Step 'all' }
        else       { Write-DemoLine Fail 'No diagnostic settings on the host pool' -Step 'all' }
    }
    else {
        Write-DemoLine Info 'Az.Monitor not loaded, diagnostic settings not checked'
    }
    Write-Host ''
}

#endregion

#region Flip 1: VM Administrator Login --------------------------------------------------

function Grant-AvdDemoAdminLogin {
    <#
    .SYNOPSIS
        PREP ONLY. Creates the misconfiguration for the demo: VM Administrator Login for one test user.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SignInName)
    $ctx = Get-DemoContext
    foreach ($rg in $ctx.VmResourceGroups) {
        if ($PSCmdlet.ShouldProcess("$SignInName on $rg", "Assign $script:RoleAdmin")) {
            $null = New-AzRoleAssignment -SignInName $SignInName -RoleDefinitionName $script:RoleAdmin -ResourceGroupName $rg
            Write-DemoLine Fail "$SignInName now has VM Administrator Login on $rg (demo misconfiguration)" -Step 4
        }
    }
    Write-Host '  Allow a few minutes for RBAC to propagate, then sign in fresh as that user.' -ForegroundColor Yellow
}

function Revoke-AvdDemoAdminLogin {
    <#
    .SYNOPSIS
        The live fix: removes VM Administrator Login for a user on the sessionhost resource group(s).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SignInName)
    $ctx = Get-DemoContext
    foreach ($rg in $ctx.VmResourceGroups) {
        $a = Get-AzRoleAssignment -SignInName $SignInName -RoleDefinitionName $script:RoleAdmin -ResourceGroupName $rg -ErrorAction SilentlyContinue |
             Where-Object Scope -like "*/resourceGroups/$rg"
        if (-not $a) { Write-DemoLine Info "No VM Administrator Login for $SignInName on $rg"; continue }
        if ($PSCmdlet.ShouldProcess("$SignInName on $rg", "Remove $script:RoleAdmin")) {
            Remove-AzRoleAssignment -SignInName $SignInName -RoleDefinitionName $script:RoleAdmin -ResourceGroupName $rg | Out-Null
            Write-DemoLine Ok "Removed VM Administrator Login for $SignInName on $rg" -Step 4
        }
    }
    Write-Host '  Takes effect at the next sign-in. That is why this is a recurring check, not a one-off.' -ForegroundColor Yellow
}

function Get-AvdDemoLocalAdministrator {
    <#
    .SYNOPSIS
        Lists the local Administrators group on every sessionhost (the fleet query from Part II).
    #>
    [CmdletBinding()]
    param()
    $null = Get-DemoContext
    $script = @"
`$inList = `$false
foreach (`$line in (net localgroup Administrators)) {
    if (`$line -like '-----*') { `$inList = `$true; continue }
    if (`$inList -and `$line -and `$line -notmatch '^The command completed') { 'member: ' + `$line }
}
"@
    Write-DemoHeader 'Local Administrators across the host pool'
    Write-HostScriptResult (Invoke-DemoHostScript -Script $script)
}

#endregion

#region Flip 2: redirection, configuration vs enforcement -------------------------------

function Set-AvdDemoRedirection {
    <#
    .SYNOPSIS
        Flips redirection in the host pool RDP properties (the configuration side).
    .EXAMPLE
        Set-AvdDemoRedirection -Clipboard On -Drives On
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('On', 'Off')][string]$Clipboard,
        [ValidateSet('On', 'Off')][string]$Drives,
        [ValidateSet('On', 'Off')][string]$Printers
    )
    $ctx   = Get-DemoContext
    $hp    = Get-AzWvdHostPool -Name $ctx.HostPoolName -ResourceGroupName $ctx.ResourceGroupName
    $props = ConvertFrom-RdpPropertyString $hp.CustomRdpProperty
    $before = [ordered]@{}
    foreach ($k in $props.Keys) { $before[$k] = $props[$k] }

    if ($PSBoundParameters.ContainsKey('Clipboard')) { $props['redirectclipboard'] = "redirectclipboard:i:$([int]($Clipboard -eq 'On'))" }
    if ($PSBoundParameters.ContainsKey('Drives'))    { $props['drivestoredirect']  = if ($Drives -eq 'On') { 'drivestoredirect:s:*' } else { 'drivestoredirect:s:' } }
    if ($PSBoundParameters.ContainsKey('Printers'))  { $props['redirectprinters']  = "redirectprinters:i:$([int]($Printers -eq 'On'))" }

    $new = ConvertTo-RdpPropertyString $props
    if ($PSCmdlet.ShouldProcess($hp.Name, 'Update CustomRdpProperty')) {
        $null = Update-AzWvdHostPool -Name $ctx.HostPoolName -ResourceGroupName $ctx.ResourceGroupName -CustomRdpProperty $new
    }

    Write-DemoHeader "RDP properties on $($hp.Name)"
    foreach ($k in @('redirectclipboard', 'drivestoredirect', 'redirectprinters')) {
        $old = if ($before.Contains($k)) { $before[$k] } else { '(not set)' }
        $cur = if ($props.Contains($k))  { $props[$k] }  else { '(not set)' }
        $status = if ($old -eq $cur) { 'Info' } else { 'Warn' }
        Write-DemoLine $status ('{0,-28} -> {1}' -f $old, $cur) -Step 5
    }
    Write-Host ''
    Write-Host '  Users pick this up after a feed refresh and a NEW connection (sign out, not disconnect).' -ForegroundColor Yellow
}

function Set-AvdDemoHostEnforcement {
    <#
    .SYNOPSIS
        Sets or clears the OS-side redirection policy on the sessionhosts (the enforcement side).
    .DESCRIPTION
        Enforced writes, under HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services:
          fDisableCdm = 1   Do not allow drive redirection
          SCClipLevel = 0   Clipboard host -> client: disabled
          CSClipLevel = 1   Clipboard client -> host: plain text only
        -Watermark adds fEnableWatermarking with the documented default QR settings.
        Microsoft documents a restart for these to take effect, so use -Restart.
        If Intune or Group Policy manages the same values, they come back at the next sync.
    .EXAMPLE
        Set-AvdDemoHostEnforcement -State Enforced -Restart
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('Enforced', 'Cleared')][string]$State,
        [switch]$Watermark,
        [switch]$Restart
    )
    $ctx   = Get-DemoContext
    $key   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $names = ($script:TsPolicyValues | ForEach-Object { "'$_'" }) -join ','

    if ($State -eq 'Enforced') {
        $lines = @(
            "`$k = '$key'"
            "if (-not (Test-Path `$k)) { `$null = New-Item -Path `$k -Force }"
            "`$null = New-ItemProperty -Path `$k -Name fDisableCdm -PropertyType DWord -Value 1 -Force"
            "`$null = New-ItemProperty -Path `$k -Name SCClipLevel -PropertyType DWord -Value 0 -Force"
            "`$null = New-ItemProperty -Path `$k -Name CSClipLevel -PropertyType DWord -Value 1 -Force"
        )
        if ($Watermark) {
            $lines += @(
                "`$null = New-ItemProperty -Path `$k -Name fEnableWatermarking -PropertyType DWord -Value 1 -Force"
                "`$null = New-ItemProperty -Path `$k -Name WatermarkingOpacity -PropertyType DWord -Value 2000 -Force"
                "`$null = New-ItemProperty -Path `$k -Name WatermarkingQrScale -PropertyType DWord -Value 4 -Force"
                "`$null = New-ItemProperty -Path `$k -Name WatermarkingWidthFactor -PropertyType DWord -Value 320 -Force"
                "`$null = New-ItemProperty -Path `$k -Name WatermarkingHeightFactor -PropertyType DWord -Value 180 -Force"
            )
        }
    }
    else {
        $lines = @(
            "`$k = '$key'"
            "foreach (`$n in @($names)) { Remove-ItemProperty -Path `$k -Name `$n -ErrorAction SilentlyContinue }"
        )
    }
    $lines += @(
        "`$v = Get-ItemProperty -Path `$k -ErrorAction SilentlyContinue"
        "foreach (`$n in @($names)) { if (`$v -and `$null -ne `$v.`$n) { '{0,-26} = {1}' -f `$n, `$v.`$n } }"
        "'(done)'"
    )

    if ($PSCmdlet.ShouldProcess($ctx.HostPoolName, "Host enforcement: $State")) {
        Write-DemoHeader "Host enforcement: $State"
        Write-HostScriptResult (Invoke-DemoHostScript -Script ($lines -join "`n"))
        if ($Restart) {
            foreach ($h in Get-DemoSessionHostVm) {
                $null = Restart-AzVM -ResourceGroupName $h.VmResourceGroup -Name $h.VmName -AsJob
                Write-Host "  Restart requested for $($h.VmName) (running in the background)" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host '  Not restarted. Microsoft documents a restart for these settings; use -Restart if a new session does not show the change.' -ForegroundColor Yellow
        }
    }
}

function Get-AvdDemoHostEnforcement {
    <#
    .SYNOPSIS
        Reads the Terminal Services policy values on each sessionhost, whoever set them.
    #>
    [CmdletBinding()]
    param()
    $names  = ($script:TsPolicyValues + @('fDisableClip', 'fEnableScreenCaptureProtect', 'fEnableScreenCaptureProtection') |
               ForEach-Object { "'$_'" }) -join ','
    $script = @"
`$v = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
foreach (`$n in @($names)) { if (`$v -and `$null -ne `$v.`$n) { '{0,-30} = {1}' -f `$n, `$v.`$n } }
'(done)'
"@
    Write-DemoHeader 'Terminal Services policy on the sessionhosts (enforcement)'
    Write-HostScriptResult (Invoke-DemoHostScript -Script $script)
}

#endregion

#region Flip 3: a public IP -------------------------------------------------------------

function New-AvdDemoPublicIpPolicy {
    <#
    .SYNOPSIS
        PREP ONLY. Assigns the built-in 'Not allowed resource types' policy, denying public IPs.
        Do this well before the session: a new assignment can take up to 30 minutes to bite.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$AssignmentName = 'deny-public-ip-sessionhosts')
    $ctx = Get-DemoContext
    $def = Get-AzPolicyDefinition -Id $script:NotAllowedTypesDefId
    foreach ($rg in $ctx.VmResourceGroups) {
        $scope = (Get-AzResourceGroup -Name $rg).ResourceId
        if ($PSCmdlet.ShouldProcess($scope, 'Assign Not allowed resource types (publicIPAddresses)')) {
            $null = New-AzPolicyAssignment -Name $AssignmentName -DisplayName 'Deny public IPs on AVD sessionhosts' `
                    -Scope $scope -PolicyDefinition $def `
                    -PolicyParameterObject @{ listOfResourceTypesNotAllowed = @('Microsoft.Network/publicIPAddresses') }
            Write-DemoLine Ok "Assigned on $rg. Give it up to 30 minutes before you rely on it." -Step 6
        }
    }
}

function Test-AvdDemoPublicIp {
    <#
    .SYNOPSIS
        The live flip: tries to create a public IP next to the sessionhosts. Policy should refuse it.
        If it is created, it is removed again straight away.
    #>
    [CmdletBinding()]
    param([string]$ResourceGroupName)
    $ctx = Get-DemoContext
    $rg   = if ($ResourceGroupName) { $ResourceGroupName } else { $ctx.VmResourceGroups[0] }
    $loc  = (Get-AzResourceGroup -Name $rg).Location
    $name = 'pip-avd-demo-{0}' -f (Get-Random -Maximum 99999)

    Write-DemoHeader "Creating public IP '$name' in $rg"
    try {
        $null = New-AzPublicIpAddress -Name $name -ResourceGroupName $rg -Location $loc `
                    -Sku Standard -AllocationMethod Static -ErrorAction Stop
        Write-DemoLine Fail 'Created. Nothing stops the next troubleshooting session from doing this.' -Step 6
        Remove-AzPublicIpAddress -Name $name -ResourceGroupName $rg -Force
        Write-Host '  (removed it again)' -ForegroundColor DarkGray
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'RequestDisallowedByPolicy|disallowed by policy') {
            Write-DemoLine Ok 'Denied by Azure Policy: RequestDisallowedByPolicy' -Step 6
            $short = if ($msg.Length -gt 420) { $msg.Substring(0, 420) + ' ...' } else { $msg }
            Write-Host "  $short" -ForegroundColor DarkGray
        }
        else {
            throw
        }
    }
}

#endregion

#region Reset ---------------------------------------------------------------------------

function Reset-AvdDemo {
    <#
    .SYNOPSIS
        Puts the demo back: baseline RDP properties and host policy values cleared.
        Use -Restart to restart the sessionhosts afterwards.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Restart)
    $ctx = Get-DemoContext

    if (Test-Path $ctx.BaselineFile) {
        $baseline = (Get-Content $ctx.BaselineFile -Raw | ConvertFrom-Json).CustomRdpProperty
        if ($PSCmdlet.ShouldProcess($ctx.HostPoolName, 'Restore baseline RDP properties')) {
            $null = Update-AzWvdHostPool -Name $ctx.HostPoolName -ResourceGroupName $ctx.ResourceGroupName -CustomRdpProperty $baseline
            Write-DemoLine Ok 'Baseline RDP properties restored'
        }
    }
    else {
        Write-DemoLine Warn "No baseline file at $($ctx.BaselineFile), RDP properties left as they are"
    }

    $names  = ($script:TsPolicyValues | ForEach-Object { "'$_'" }) -join ','
    $script = @"
`$k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
foreach (`$n in @($names)) { Remove-ItemProperty -Path `$k -Name `$n -ErrorAction SilentlyContinue }
'host policy values cleared'
"@
    if ($PSCmdlet.ShouldProcess($ctx.HostPoolName, 'Clear host policy values')) {
        Write-HostScriptResult (Invoke-DemoHostScript -Script $script)
        if ($Restart) {
            foreach ($h in Get-DemoSessionHostVm) {
                $null = Restart-AzVM -ResourceGroupName $h.VmResourceGroup -Name $h.VmName -AsJob
                Write-Host "  Restart requested for $($h.VmName)" -ForegroundColor Yellow
            }
        }
    }
    Write-Host '  For the next run: Grant-AvdDemoAdminLogin -SignInName <poweruser> brings back the flip 1 misconfiguration.' -ForegroundColor DarkGray
}

#endregion

Export-ModuleMember -Function @(
    'Get-AvdDemoEnvironment'
    'Initialize-AvdDemo'
    'Show-AvdDemoState'
    'Grant-AvdDemoAdminLogin'
    'Revoke-AvdDemoAdminLogin'
    'Get-AvdDemoLocalAdministrator'
    'Set-AvdDemoRedirection'
    'Set-AvdDemoHostEnforcement'
    'Get-AvdDemoHostEnforcement'
    'New-AvdDemoPublicIpPolicy'
    'Test-AvdDemoPublicIp'
    'Reset-AvdDemo'
)

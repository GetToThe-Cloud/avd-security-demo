#Requires -Version 7.2
<#
.SYNOPSIS
    Presenter script for the 15-minute AVD security demo.
    gettothe.cloud - Azure Virtual Desktop | Securing Your Environment

.DESCRIPTION
    Walks you through the demo one step at a time. Every step shows:
      - the time slot and the chain step it belongs to
      - what to do by hand (in the sessions, the portal, Log Analytics)
      - the command it is about to run
      - the line to say
    Then it waits for you. Keys at the prompt:
      Enter = run the step (or continue)   s = skip this step's command   q = quit

    Needs AvdSecurityDemo.psm1 in the same folder, PowerShell 7.2+ and the Az modules.
    Run Connect-AzAccount first.

    After 01-Deploy-Environment.ps1 every parameter is optional: the lab's host pool and
    demo users come from scripts/demo-environment.json.

.EXAMPLE
    # The lab built with 01-Deploy-Environment.ps1
    ./Start-AvdDemo.ps1 -Watermark

.EXAMPLE
    # A host pool of your own
    ./Start-AvdDemo.ps1 -SubscriptionId <id> -ResourceGroupName rg-avd-demo -HostPoolName hp-avd-demo `
                        -PowerUserSignInName avd.poweruser@contoso.com

.EXAMPLE
    # Read the whole run of show without touching Azure
    ./Start-AvdDemo.ps1 -Preview

.EXAMPLE
    # Pick up again at step 6 after a hiccup
    ./Start-AvdDemo.ps1 ... -StartAt 6
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console output for a presenter at a terminal, not objects for a pipeline')]
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$HostPoolName,
    [string]$PowerUserSignInName,
    [string]$UserSignInName,
    [switch]$Watermark,
    [ValidateRange(1, 9)][int]$StartAt = 1,
    [switch]$SkipReset,
    [switch]$Preview
)

$ErrorActionPreference = 'Stop'

# Fill in whatever was not passed from the lab built by 01-Deploy-Environment.ps1.
$environmentFile = Join-Path $PSScriptRoot 'demo-environment.json'
if (Test-Path -Path $environmentFile) {
    $environment = Get-Content -Path $environmentFile -Raw | ConvertFrom-Json
    if (-not $SubscriptionId)      { $SubscriptionId      = $environment.subscriptionId }
    if (-not $ResourceGroupName)   { $ResourceGroupName   = $environment.resourceGroups.core }
    if (-not $HostPoolName)        { $HostPoolName        = $environment.hostPool.name }
    if (-not $PowerUserSignInName) { $PowerUserSignInName = $environment.users.powerUser }
    if (-not $UserSignInName)      { $UserSignInName      = $environment.users.user }
}
if (-not $UserSignInName) { $UserSignInName = 'avd.user' }
if ($Preview) {
    if (-not $HostPoolName)        { $HostPoolName        = '<host pool>' }
    if (-not $PowerUserSignInName) { $PowerUserSignInName = 'avd.poweruser@<tenant>' }
}
elseif (-not ($SubscriptionId -and $ResourceGroupName -and $HostPoolName -and $PowerUserSignInName)) {
    throw 'Pass -SubscriptionId, -ResourceGroupName, -HostPoolName and -PowerUserSignInName, or deploy the lab with 01-Deploy-Environment.ps1 first.'
}

#region Presenter helpers ---------------------------------------------------------------

$script:DemoClock   = $null
$script:RestartJobs = @()

function Get-Elapsed {
    if (-not $script:DemoClock) { return '--:--' }
    $e = (Get-Date) - $script:DemoClock
    '{0:00}:{1:00}' -f [math]::Floor($e.TotalMinutes), $e.Seconds
}

function Show-StepHeader {
    param($Step, [int]$Total)
    if (-not $Preview) { Clear-Host }
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ('  STEP {0}/{1}   {2}   {3}' -f $Step.Number, $Total, $Step.Time, $Step.Title) -ForegroundColor Cyan
    Write-Host ('  Chain: {0,-30} Clock: {1} (target {2})' -f $Step.Chain, (Get-Elapsed), $Step.Time) -ForegroundColor DarkGray
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Show-Block {
    param([string]$Label, [string[]]$Lines, [string]$Color = 'White')
    if (-not $Lines) { return }
    Write-Host ''
    Write-Host "  $Label" -ForegroundColor DarkGray
    $i = 0
    foreach ($l in $Lines) {
        $i++
        Write-Host ("   {0}. {1}" -f $i, $l) -ForegroundColor $Color
    }
}

function Show-Say {
    param([string]$Text)
    if (-not $Text) { return }
    Write-Host ''
    Write-Host '  SAY' -ForegroundColor DarkGray
    Write-Host "   ""$Text""" -ForegroundColor Yellow
}

function Read-Presenter {
    param([string]$Prompt)
    if ($Preview) { return 'run' }
    Write-Host ''
    $answer = Read-Host "  >> $Prompt  [Enter = go, s = skip, q = quit]"
    switch ($answer.Trim().ToLowerInvariant()) {
        'q'     { 'quit' }
        's'     { 'skip' }
        default { 'run' }
    }
}

function Wait-DemoHostAvailable {
    param([int]$TimeoutSeconds = 300)
    if ($script:RestartJobs) {
        Write-Host '  Waiting for the restart job(s) to finish...' -ForegroundColor DarkGray
        $null = $script:RestartJobs | Wait-Job -Timeout $TimeoutSeconds
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $hosts  = @(Get-AzWvdSessionHost -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName)
        $status = ($hosts | ForEach-Object { '{0}: {1}' -f ($_.Name -split '/')[-1], $_.Status }) -join ', '
        Write-Host "  $status" -ForegroundColor Gray
        if ($hosts -and -not ($hosts | Where-Object Status -ne 'Available')) {
            Write-Host '  Host is Available. Connect now.' -ForegroundColor Green
            return
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    Write-Host '  Still not Available. Use the fallback screenshot or wait a little longer.' -ForegroundColor Yellow
}

#endregion

#region The run of show -----------------------------------------------------------------

$steps = @(
    @{
        Number = 1; Time = '00:00'; Title = "What's built"; Chain = 'all six'
        Before = @()
        CommandText = 'Show-AvdDemoState'
        Command = { Show-AvdDemoState }
        After = @(
            'Walk the screen top to bottom: SSO, roles, Trusted Launch, no public IP, redirection off, policy, diagnostics.'
            'Optional, 20 seconds in the portal: VM Overview shows Security type Trusted launch, Networking shows no public IP.'
            'End on the one red line: the poweruser with VM Administrator Login.'
        )
        Say = "This is the check I run first in every environment. Everything maps to a step in the chain. One red line, the most common serious finding I get called in for. That's our first flip."
    }
    @{
        Number = 2; Time = '01:30'; Title = 'Flip 1: two users, one role'; Chain = '4 Elevation'
        Before = @(
            "In the $UserSignInName session, open a terminal and run:  whoami /groups | findstr /i ""S-1-5-32-544""   (no output)"
            "Switch to the poweruser session and run the same command   (BUILTIN\Administrators appears)"
            'Portal: sessionhost resource group > Access control (IAM) > Role assignments > Virtual Machine Administrator Login'
        )
        CommandText = $null
        Command = $null
        After = @()
        Say = "Same host pool, same image. The only difference is one role in the portal, and it makes this user a local administrator on a shared machine. Every OS control in Part II assumes that is not the case."
    }
    @{
        Number = 3; Time = '03:30'; Title = 'Flip 1: the fix'; Chain = '4 Elevation'
        Before = @()
        CommandText = "Revoke-AvdDemoAdminLogin -SignInName $PowerUserSignInName"
        Command = { Revoke-AvdDemoAdminLogin -SignInName $PowerUserSignInName -Confirm:$false }
        After = @()
        Say = "Nobody needed an exploit, it was granted in the portal. The removal works at the next sign-in, and the grant tends to come back at 4pm on a Friday. Recurring check, not a one-off."
    }
    @{
        Number = 4; Time = '04:30'; Title = 'Flip 2: open redirection (configuration)'; Chain = '5 Data'
        Before = @(
            "In the $UserSignInName session: open Q3-customer-list.txt, copy a line, paste it in Notepad on the laptop   (nothing arrives)"
            'File Explorer > This PC   (no laptop drives)'
        )
        CommandText = 'Set-AvdDemoRedirection -Clipboard On -Drives On'
        Command = { Set-AvdDemoRedirection -Clipboard On -Drives On -Confirm:$false }
        After = @(
            'Windows App: refresh the workspace'
            'Sign OUT of the session (not disconnect) and connect again'
            'Copy the same line again: it pastes on the laptop'
            "This PC now shows the laptop's C drive"
        )
        Say = "One host pool property. Clipboard is the exfiltration route people forget, because it doesn't feel like a file transfer. It is one, and it's scriptable."
    }
    @{
        Number = 5; Time = '07:30'; Title = 'Flip 2: enforce on the host'; Chain = '5 Data'
        Before = @('Leave the RDP properties OPEN on purpose. We are only changing the host.')
        CommandText = 'Set-AvdDemoHostEnforcement -State Enforced -Restart' + $(if ($Watermark) { ' -Watermark' } else { '' })
        Command = {
            $before = @(Get-Job | Select-Object -ExpandProperty Id)
            Set-AvdDemoHostEnforcement -State Enforced -Restart -Watermark:$Watermark -Confirm:$false
            $script:RestartJobs = @(Get-Job | Where-Object Id -notin $before)
        }
        After = @('The host restarts in the background. Go straight to flip 3.')
        Say = "The host pool property is configuration. What I just set on the host is enforcement. I left the configuration open, so in a few minutes we'll see who wins."
    }
    @{
        Number = 6; Time = '08:00'; Title = 'Flip 3: a public IP'; Chain = '6 Lateral movement'
        Before = @()
        CommandText = 'Test-AvdDemoPublicIp'
        Command = { Test-AvdDemoPublicIp }
        After = @(
            'Point back at the "no public IP" line from step 1'
            'If there is time: one sentence on Private Link and DNS'
        )
        Say = "Reverse connect: the host dials out, nothing dials in, so a sessionhost never needs a public IP. When I find one, somebody needed to troubleshoot once. A policy stops the next one. A wiki page doesn't."
    }
    @{
        Number = 7; Time = '10:30'; Title = 'Back in the session: enforcement wins'; Chain = '5 Data'
        Before = @('Waiting until the host is Available again (runs automatically)')
        CommandText = 'Get-AvdDemoHostEnforcement'
        Command = {
            Wait-DemoHostAvailable
            Write-Host ''
            Write-Host "  Connect as $UserSignInName (new session) and check This PC and the clipboard, then press Enter." -ForegroundColor White
            if (-not $Preview) { $null = Read-Host '  >> Enter when connected' }
            Get-AvdDemoHostEnforcement
        }
        After = @(
            'This PC: no laptop drive, although the RDP property still says drivestoredirect:s:*'
            'Laptop -> session: plain text pastes.  Session -> laptop: nothing.'
            $(if ($Watermark) { 'QR codes on screen. Only supported clients can connect now.' } else { 'Point at fDisableCdm = 1, SCClipLevel = 0, CSClipLevel = 1' })
        )
        Say = "Configuration said yes, enforcement said no, and the restrictive one won. You only know because you tested the session, not the portal."
    }
    @{
        Number = 8; Time = '12:30'; Title = 'Flip 4: did anybody notice?'; Chain = '2 Token + detection'
        Before = @(
            'Log Analytics: run kql/avd-signins.kql'
            'Show the two rows per connection: Azure Virtual Desktop and Windows Cloud Login, with the CA result'
            'Run kql/connections.kql (WVDConnections): user, host, client IP, transport'
            "No rows from today yet? Set Window to 1d and show the rehearsal. Still nothing: kql/lab-health.kql."
            'Close: the next detection to build is kql/local-admin-changes.kql.'
        )
        CommandText = $null
        Command = $null
        After = @()
        Say = "The sign-in log is the truth, the policy list is the intention. Both moments are here because SSO moved the host sign-in under Entra. A policy on only one of these apps leaves the other one open."
    }
    @{
        Number = 9; Time = '14:30'; Title = 'Reset'; Chain = '-'
        Before = @()
        CommandText = $(if ($SkipReset) { '(reset skipped: -SkipReset)' } else { 'Reset-AvdDemo -Restart' })
        Command = { if (-not $SkipReset) { Reset-AvdDemo -Restart -Confirm:$false } }
        After = @(
            'Back to the deck: slide 27, "Ask which step a control cuts."'
            "Next run: Grant-AvdDemoAdminLogin -SignInName $PowerUserSignInName"
        )
        Say = 'Back to baseline in one command. Questions?'
    }
)

#endregion

#region Run -----------------------------------------------------------------------------

if (-not $Preview) {
    Import-Module (Join-Path $PSScriptRoot 'AvdSecurityDemo.psm1') -Force
    Initialize-AvdDemo -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
}

Write-Host ''
Write-Host '  AVD security demo, 15 minutes, 9 steps.' -ForegroundColor Cyan
Write-Host "  Host pool: $HostPoolName   Poweruser: $PowerUserSignInName   Watermark: $([bool]$Watermark)" -ForegroundColor DarkGray
if ((Read-Presenter 'Start the clock') -eq 'quit') { return }
$script:DemoClock = Get-Date

foreach ($step in ($steps | Where-Object { $_.Number -ge $StartAt })) {
    Show-StepHeader -Step $step -Total $steps.Count
    Show-Block -Label 'DO' -Lines $step.Before

    if ($step.Command) {
        Write-Host ''
        Write-Host "  RUN   $($step.CommandText)" -ForegroundColor Magenta
        $choice = Read-Presenter 'Run it'
        if ($choice -eq 'quit') { break }
        if ($choice -eq 'run' -and -not $Preview) {
            try { & $step.Command }
            catch { Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red; Write-Host '  Use the fallback for this step.' -ForegroundColor Yellow }
        }
    }

    Show-Block -Label 'THEN' -Lines $step.After
    Show-Say -Text $step.Say

    if ($step.Number -lt $steps.Count) {
        if ((Read-Presenter 'Next step') -eq 'quit') { break }
    }
}

Write-Host ''
Write-Host "  Demo done in $(Get-Elapsed). Share and Enjoy !" -ForegroundColor Cyan

#endregion

# Registers this VM as a sessionhost: downloads the Azure Virtual Desktop Agent and
# Agent Boot Loader from Microsoft's download links, checks that both are signed by
# Microsoft, and installs them with the host pool's registration token.
#
# Runs once through the Custom Script Extension in sessionhost.bicep, which loads this
# file, puts the token in place of the placeholder and passes it in protected settings.
# Windows PowerShell 5.1, as SYSTEM.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$registrationToken = '__REGISTRATION_TOKEN__'
$workFolder = Join-Path -Path $env:SystemDrive -ChildPath 'AVDAgent'

if (Get-Service -Name 'RDAgentBootLoader' -ErrorAction SilentlyContinue) {
    'The AVD agent is already installed. Nothing to do.'
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$null = New-Item -Path $workFolder -ItemType Directory -Force

$installers = @(
    @{ Name = 'RDAgent'; Uri = 'https://go.microsoft.com/fwlink/?linkid=2310011' }
    @{ Name = 'RDAgentBootLoader'; Uri = 'https://go.microsoft.com/fwlink/?linkid=2311028' }
)

foreach ($installer in $installers) {
    $msi = Join-Path -Path $workFolder -ChildPath "$($installer.Name).msi"
    Invoke-WebRequest -Uri $installer.Uri -OutFile $msi -UseBasicParsing
    Unblock-File -Path $msi

    # An image is a supply chain: install only what Microsoft signed.
    $signature = Get-AuthenticodeSignature -FilePath $msi
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "$($installer.Name).msi failed the signature check: $($signature.Status), $($signature.SignerCertificate.Subject)"
    }

    $arguments = @('/i', "`"$msi`"", '/quiet', '/norestart', '/l*v', "`"$workFolder\$($installer.Name).log`"")
    if ($installer.Name -eq 'RDAgent') {
        $arguments += "REGISTRATIONTOKEN=$registrationToken"
    }
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) {
        throw "$($installer.Name).msi failed with exit code $($process.ExitCode). See $workFolder\$($installer.Name).log"
    }
    "$($installer.Name) installed."
}

'Registration done. The host shows up in the host pool within a few minutes.'

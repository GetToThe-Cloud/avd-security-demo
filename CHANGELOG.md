# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1] - 2026-10-19

### Fixed

- `kql/avd-signins.kql` and `kql/new-country-signin.kql` read only interactive sign-ins and
  missed most AVD traffic: once Windows App holds a token, its sign-ins are non-interactive.
  Both now also read `AADNonInteractiveUserSignInLogs`.
- `02-Test-Environment.ps1` checks for AVD sign-ins in both tables instead of any interactive
  sign-in.

### Added

- `kql/lab-health.kql`: which tables have reached the workspace and when, for when the live
  queries come back empty.
- A `Window` setting at the top of the live queries.

## [1.1.0] - 2026-10-17

### Added

- Bicep to build the lab from zero, split over two resource groups: network with a
  NAT gateway, Log Analytics, a pooled host pool with the secured baseline RDP
  properties, desktop and workspace with diagnostics; and on the hosts resource group
  one Trusted Launch, Entra-joined Windows 11 multi-session sessionhost without a
  public IP, the VM User Login roles and the deny-public-IP policy.
- Agent registration that checks the Microsoft signature on the agent and boot loader
  before installing them.
- `00-Prerequisites.ps1`, `01-Deploy-Environment.ps1` (two phases, a short-lived
  registration token that is removed afterwards, the flip 1 misconfiguration, optional
  Entra ID sign-in logs), `02-Test-Environment.ps1` and `99-Remove-Environment.ps1`.
- `Get-AvdDemoEnvironment`.

### Changed

- `Initialize-AvdDemo` and `Start-AvdDemo.ps1` read the deployed lab from
  `scripts/demo-environment.json`, so they need no parameters after a deployment.

## [1.0.0] - 2026-10-14

### Added

- `AvdSecurityDemo.psm1`: a posture check of one host pool mapped to the attack
  chain, and functions for every flip in the demo: VM Administrator Login,
  redirection in the RDP properties, host-side enforcement, a public IP against
  Azure Policy, and a reset to the saved baseline.
- `Start-AvdDemo.ps1`: a presenter script that walks through the fifteen-minute
  demo one step at a time, with a preview mode and a way to resume at any step.
- KQL for both AVD authentication moments and for connections, used live, plus
  templates for local admin changes, new sign-in countries, new egress
  destinations and FSLogix failure rates.

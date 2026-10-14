# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

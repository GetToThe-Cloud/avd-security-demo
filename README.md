# AVD security: demo environment

A fifteen-minute live demo that shows what a secured Azure Virtual Desktop host pool looks like, then flips one setting at a time and lets the audience see what changes in a real session.

Companion code for the [gettothe.cloud](https://www.gettothe.cloud) session *Azure Virtual Desktop | Securing Your Environment*, the three-part series on the trust boundary, identity and the sessionhost, and network, data and detection. Every flip in the demo maps to a step in the attack chain from the talk: credential, token, host, elevation, data, lateral movement.

The scripts change Azure on your behalf: the RDP properties of a host pool, Terminal Services policy values on the sessionhost (through Run Command), one role assignment and one policy assignment. Point them at a lab host pool, read them before you run them, and treat this as a demo, not a production pattern. `Reset-AvdDemo` puts the RDP properties and the host values back; the role and the policy are yours to keep or remove.

Bring a host pool of your own, or build the lab from zero with the Bicep and the numbered scripts in this repository: two resource groups, one secured host pool and one sessionhost, ready in about half an hour.

## What the lab needs

| Piece | What | Role in the demo |
| --- | --- | --- |
| Host pool | Pooled, Entra-joined, single sign-on on (`enablerdsaadauth:i:1`) | The thing we inspect and flip |
| Sessionhost | Exactly one, or the others in drain mode; Trusted Launch; no public IP | Every connection lands on the host you changed |
| Baseline RDP properties | Clipboard, drives, printers and USB redirection off | The secured starting point for flip 2 |
| Two test users | `avd.user` with Virtual Machine User Login, `avd.poweruser` with Virtual Machine Administrator Login | Flip 1: same image, one role apart |
| Azure Policy | Not allowed resource types, denying `Microsoft.Network/publicIPAddresses` on the sessionhost resource group | Flip 3 |
| Log Analytics | Host pool diagnostics and Entra ID sign-in logs in the same workspace | Flip 4 |

Make sure nothing else manages the Terminal Services redirection values on the demo host. If Intune or Group Policy sets them, your changes come back at the next sync. That is a good story about two policy sources, but a bad live demo.

## Build the lab from zero

`bicep/main.bicep` builds exactly the lab above, split over two resource groups so every control lands where the talk says it belongs.

| Resource group | What | Why it's there |
| --- | --- | --- |
| `rg-avdsec-core` | Virtual network with a private subnet, an NSG without inbound rules, a NAT gateway | Reverse connect: nothing dials in, the host dials out through the NAT gateway |
| `rg-avdsec-core` | Log Analytics workspace, diagnostics on the host pool, application group and workspace | Flip 4, and the `kql` folder |
| `rg-avdsec-core` | Pooled host pool `vdpool-avdsec` with the secured baseline RDP properties, a desktop application group, the workspace | The control plane objects you own |
| `rg-avdsec-hosts` | One Windows 11 Enterprise multi-session VM: Trusted Launch with Secure Boot, vTPM and Guest Attestation, joined to Entra ID, no public IP | The sessionhost the demo flips |
| `rg-avdsec-hosts` | Virtual Machine User Login for both demo users, and the Not allowed resource types policy denying public IPs | Roles and policy scoped to the sessionhosts, not the subscription |

The NAT gateway's public IP sits in the core resource group on purpose: the deny policy only covers the hosts resource group, so the lab never blocks itself.

You need two existing Entra ID users, licensed for Azure Virtual Desktop, for `avd.user` and `avd.poweruser`. The scripts don't create accounts.

```powershell
cd scripts
./00-Prerequisites.ps1 -SubscriptionId <subscription-id> -InstallMissingModules
./00-Prerequisites.ps1 -SubscriptionId <subscription-id> -EnableEntraSso   # once per tenant, if SSO isn't on yet
./01-Deploy-Environment.ps1 -SubscriptionId <subscription-id> -UserUpn avd.user@<tenant> -PowerUserUpn avd.poweruser@<tenant> -ConnectEntraSignInLogs
./02-Test-Environment.ps1
```

`00-Prerequisites.ps1` checks the modules and the Bicep CLI, registers the resource providers, and checks that the region, the VM size (Gen2 with Trusted Launch), the image and your vCPU quota work. With `-EnableEntraSso` it switches on Microsoft Entra authentication for RDP on the Windows Cloud Login service principal, which the host pool's `enablerdsaadauth:i:1` needs.

`01-Deploy-Environment.ps1` deploys `main.bicep` twice. The `core` phase builds everything except the VM. The script then creates a registration token that is valid for two hours, and the `sessionhost` phase adds the VM, which joins Entra ID and installs the AVD agent and boot loader. The registration script checks that both installers carry a valid Microsoft signature before it runs them. The script waits until the host is Available, restarts it once as Microsoft's registration steps say, and then removes the registration token: it's a credential that lets any machine join the pool. Finally it gives `avd.poweruser` Virtual Machine Administrator Login, the misconfiguration flip 1 removes on stage, and writes everything to `scripts/demo-environment.json`. Count on 20 to 30 minutes.

`-ConnectEntraSignInLogs` sends the tenant's Entra ID sign-in logs to the lab's workspace, which `kql/avd-signins.kql` needs. It's a tenant-wide diagnostic setting, so it needs a Security Administrator or Global Administrator and Entra ID P1 or P2. Leave it out if your sign-in logs already go to a workspace you can query.

`02-Test-Environment.ps1` is the go/no-go check: host Available, roles and the flip 1 misconfiguration in place, the policy at least 30 minutes old, the RDP properties at the baseline, data arriving in Log Analytics. It ends with `Show-AvdDemoState`.

Once the lab exists, `Initialize-AvdDemo` and `Start-AvdDemo.ps1` need no parameters: they read `scripts/demo-environment.json`.

## Before you start

You need PowerShell 7.2 or later with Az.Accounts, Az.DesktopVirtualization, Az.Compute, Az.Network and Az.Resources. Az.Monitor is optional and only used for the diagnostic settings check.

The account you run it with needs to change RDP properties (Desktop Virtualization Host Pool Contributor), run commands on and restart the sessionhost (Virtual Machine Contributor), assign roles on the sessionhost resource group (User Access Administrator) and assign a policy there (Resource Policy Contributor). Owner on the lab resource groups covers all of it.

```powershell
Connect-AzAccount
cd scripts
Import-Module ./AvdSecurityDemo.psm1 -Force
Initialize-AvdDemo   # the lab from 01-Deploy-Environment.ps1, or your own host pool:
Initialize-AvdDemo -SubscriptionId <subscription-id> -ResourceGroupName rg-avd-demo -HostPoolName hp-avd-demo
Show-AvdDemoState
```

`Initialize-AvdDemo` saves the host pool's current RDP properties to `scripts/.demo-state/` the first time it runs. That file is the baseline `Reset-AvdDemo` restores, so run it for the first time while the host pool is in its secured state.

## The day before

Built the lab with `01-Deploy-Environment.ps1`? Then the policy and the poweruser's role are already in place; run `./02-Test-Environment.ps1`. On a host pool of your own:

```powershell
New-AvdDemoPublicIpPolicy
Grant-AvdDemoAdminLogin -SignInName avd.poweruser@<tenant>
```

Both have a delay. A new policy assignment can take up to 30 minutes to start denying, and a role assignment needs a few minutes plus a fresh sign-in. Rehearse the demo end to end once and take a screenshot of every after-state; those are your fallbacks.

## Demo day

| When | Do | Why |
| --- | --- | --- |
| T-60 min | `Reset-AvdDemo -Restart`, then `./02-Test-Environment.ps1` (or `Show-AvdDemoState` on your own host pool) | Everything green except the poweruser line, which is the first flip |
| T-30 min | Windows App signed in as `avd.user`, a browser InPrivate window with the web client as `avd.poweruser` | Two sessions side by side for flip 1 |
| T-15 min | Notepad on the laptop with a line of text, `Q3-customer-list.txt` on the session desktop | Something to copy in both directions for flip 2 |
| T-5 min | The command below with `-Preview` to read the run once more; open Log Analytics with the `kql` folder | Last look, then start for real |

Then run the presenter script. It shows every step with what to do by hand, the command it is about to run and the line to say, and waits for you before it runs anything.

```powershell
./Start-AvdDemo.ps1 -SubscriptionId <subscription-id> -ResourceGroupName rg-avd-demo -HostPoolName hp-avd-demo `
                    -PowerUserSignInName avd.poweruser@<tenant> -Watermark
```

At the prompt, Enter runs the step, `s` skips its command and `q` stops. `-StartAt 6` picks the demo up again at step 6, and `-Preview` prints the whole run without touching Azure.

The run sheet (slide 26 in the deck) maps onto the script like this.

| Minute | Step | Chain step | What you show |
| --- | --- | --- | --- |
| 0-1:30 | 1, what's built | All | `Show-AvdDemoState`: one screen of green lines and one red line for the poweruser |
| 1:30-4:30 | 2 and 3, VM Administrator Login | 4 Elevation | `whoami /groups` in both sessions, the role in IAM, then `Revoke-AvdDemoAdminLogin` |
| 4:30-8:00 | 4 and 5, redirection | 5 Data | Clipboard and drives opened in the RDP properties, then enforced on the host with a restart in the background |
| 8:00-10:30 | 6, a public IP | 6 Lateral movement | `Test-AvdDemoPublicIp` ends in `RequestDisallowedByPolicy` |
| 10:30-12:30 | 7, enforcement wins | 5 Data | The RDP property still says drives on, the session shows none; the clipboard works one way only |
| 12:30-14:30 | 8, did anybody notice? | 2 Token, detection | `kql/avd-signins.kql` with two rows per connection, `kql/connections.kql` |
| 14:30-15:00 | 9, reset | | `Reset-AvdDemo -Restart`, back to the deck |

The order is deliberate. Step 5 restarts the sessionhost, and step 6 fills the minute or two that takes. Step 7 waits for the restart job and for the host to report Available before it asks you to connect.

### When something doesn't cooperate

If the poweruser is not an administrator yet, the role is still propagating. Grant it the day before, and show the rehearsal screenshot if it still lags.

If the clipboard or the drives don't open up after flip 2, the client is still using the old connection settings. Refresh the workspace in Windows App and sign out of the session instead of disconnecting; failing that, use the web client in a new InPrivate window.

If the public IP gets created, the policy assignment hasn't taken effect yet. `Test-AvdDemoPublicIp` deletes it straight away and prints a red line, and the story still works: policy has a delay, so assign it early.

If redirection still works after the restart in step 7, something else is managing those values on the host. `Get-AvdDemoHostEnforcement` shows what is actually set, which turns the problem into the point of the slide.

Log Analytics trails 5 to 15 minutes behind. If today's sign-ins aren't there yet, set `Window` to `1d` at the top of the query and show the rehearsal. If the live queries return nothing at all, run `kql/lab-health.kql`: it lists which tables have reached the workspace and when, and its header says what each result means. Most AVD sign-ins are silent token refreshes, so `kql/avd-signins.kql` reads `AADNonInteractiveUserSignInLogs` as well as `SigninLogs`.

## After the demo

```powershell
Reset-AvdDemo -Restart                                       # RDP properties and host values back to baseline
Grant-AvdDemoAdminLogin -SignInName avd.poweruser@<tenant>   # the flip 1 misconfiguration, for the next run
```

Done with the lab you built from zero?

```powershell
./99-Remove-Environment.ps1   # both resource groups, the sign-in log setting and the local state files
```

The sessionhost's device object stays in Microsoft Entra ID; the script tells you which one to delete. On a host pool of your own, remove the `deny-public-ip-sessionhosts` policy assignment and the poweruser's role assignment when you tear the lab down.

## Cost

Almost all of the cost is the sessionhost: one `Standard_D4ads_v5` with a Premium SSD OS disk while it runs. The NAT gateway and its public IP add a little per hour, and Log Analytics charges for what it ingests, which is small for one host and two users but grows if you connect a busy tenant's sign-in logs. Build the lab the day before, deallocate the VM between rehearsals if you like, and remove it after the talk.

## Things to know

Host pool RDP properties are configuration; the Terminal Services policy on the host is enforcement. Flip 2 opens the first and then closes the second, so the audience sees the restrictive one win. `Set-AvdDemoHostEnforcement -State Enforced` writes `fDisableCdm = 1` (no drive redirection), `SCClipLevel = 0` (nothing from host to client) and `CSClipLevel = 1` (plain text from client to host). Microsoft documents a restart for these settings, which is why the script restarts the host.

Clipboard direction only works when the RDP properties allow clipboard redirection in the first place, and it needs Windows 11 22H2 or later with the 2024-06 cumulative update, or Windows Server 2022 with the 2024-07 update. Disabling drive redirection on the host also blocks copying files through the clipboard.

RDP property changes reach users after a feed refresh and a new connection. Disconnecting and reconnecting keeps the old settings.

`-Watermark` adds the QR code watermark through the same registry key. Microsoft documents watermarking through Intune and Group Policy only; the registry value names here come from community scripts, so treat it as an extra and check it in your rehearsal. Once watermarking is on, only clients that support it can connect.

Conditional Access for AVD covers two moments, and `kql/avd-signins.kql` shows both: the Azure Virtual Desktop app (`9cdead84-a844-4324-93f2-b2e6bb768d07`) for the feed and the gateway, and Windows Cloud Login (`270efc09-cd0d-444b-a71f-39af4910ec45`) for the sign-in to the host with single sign-on. A policy on only one of them leaves the other one open.

## Functions

| Function | What it does | Changes Azure |
| --- | --- | --- |
| `Get-AvdDemoEnvironment` | Reads `scripts/demo-environment.json` from the lab deployment | No |
| `Initialize-AvdDemo` | Sets the context and saves the baseline RDP properties once | No |
| `Show-AvdDemoState` | One-screen posture check, every line mapped to a chain step | No |
| `Grant-AvdDemoAdminLogin` | Prep: Virtual Machine Administrator Login for the test user | Yes |
| `Revoke-AvdDemoAdminLogin` | Removes Virtual Machine Administrator Login on the sessionhost resource group | Yes |
| `Get-AvdDemoLocalAdministrator` | Lists the local Administrators group on every sessionhost | No |
| `Set-AvdDemoRedirection` | Turns clipboard, drive and printer redirection on or off in the RDP properties | Yes |
| `Set-AvdDemoHostEnforcement` | Sets or clears the host-side redirection policy, optionally watermarking and a restart | Yes |
| `Get-AvdDemoHostEnforcement` | Reads the Terminal Services policy values on every sessionhost | No |
| `New-AvdDemoPublicIpPolicy` | Prep: assigns Not allowed resource types for public IPs | Yes |
| `Test-AvdDemoPublicIp` | Tries to create a public IP and deletes it if that works | Only if the policy fails |
| `Reset-AvdDemo` | Restores the baseline RDP properties and clears the host values | Yes |

## Files

```text
bicep/
  main.bicep                   subscription-scope entry point, phases core and sessionhost
  modules/
    network.bicep              VNet, private subnet, NSG without inbound rules, NAT gateway
    monitoring.bicep           Log Analytics workspace
    avd.bicep                  host pool with the baseline RDP properties, desktop, workspace, diagnostics
    hosts-governance.bicep     VM User Login roles and the deny-public-IP policy on the hosts resource group
    sessionhost.bicep          Trusted Launch VM, Guest Attestation, Entra join, AVD agent
    Register-AvdAgent.ps1      downloads, signature-checks and installs the agent and boot loader
scripts/
  00-Prerequisites.ps1         modules, Bicep, providers, region, VM size, image, quota, Entra SSO
  01-Deploy-Environment.ps1    two-phase deployment, registration token, flip 1 misconfiguration
  02-Test-Environment.ps1      go/no-go check, ends with Show-AvdDemoState
  99-Remove-Environment.ps1    remove the lab
  AvdSecurityDemo.psm1         posture check, the flips and the reset
  Start-AvdDemo.ps1            presenter script: one step at a time, waits for you
kql/
  avd-signins.kql              both AVD authentication moments, used live
  connections.kql              WVDConnections: user, host, client IP, transport, used live
  lab-health.kql               what has reached the workspace; run it when the live queries are empty
  local-admin-changes.kql      the first detection to build after the demo
  new-country-signin.kql       template: AVD sign-in from a new country
  new-egress-destination.kql   template: a host reaching somewhere its siblings never did
  fslogix-failure-rate.kql     template: profile failures by rate, not by event
PSScriptAnalyzerSettings.psd1  analyzer settings for the scripts
CHANGELOG.md
LICENSE
```

## Sources

- [Add session hosts to a host pool: register with the agent](https://learn.microsoft.com/azure/virtual-desktop/add-session-hosts-host-pool)
- [Trusted Launch and the Guest Attestation extension](https://learn.microsoft.com/azure/virtual-machines/trusted-launch)
- [Sign in to a Windows VM in Azure with Microsoft Entra ID](https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-windows)
- [Send Entra ID sign-in logs to Log Analytics](https://learn.microsoft.com/entra/identity/monitoring-health/tutorial-configure-log-analytics-workspace)
- [Set custom RDP properties on a host pool](https://learn.microsoft.com/azure/virtual-desktop/customize-rdp-properties)
- [Configure the clipboard transfer direction](https://learn.microsoft.com/azure/virtual-desktop/clipboard-transfer-direction-data-types)
- [Configure drive redirection](https://learn.microsoft.com/azure/virtual-desktop/redirection-configure-drives-storage)
- [Watermarking in Azure Virtual Desktop](https://learn.microsoft.com/azure/virtual-desktop/watermarking)
- [Enforce Microsoft Entra MFA for Azure Virtual Desktop with Conditional Access](https://learn.microsoft.com/azure/virtual-desktop/set-up-mfa)
- [Configure single sign-on with Microsoft Entra ID](https://learn.microsoft.com/azure/virtual-desktop/configure-single-sign-on)
- [Tutorial: disallow resource types](https://learn.microsoft.com/azure/governance/policy/tutorials/disallowed-resources)
- [WVDConnections table reference](https://learn.microsoft.com/azure/azure-monitor/reference/tables/wvdconnections)
- [DeviceEvents table in advanced hunting](https://learn.microsoft.com/defender-xdr/advanced-hunting-deviceevents-table)

## License

MIT, see [LICENSE](LICENSE).

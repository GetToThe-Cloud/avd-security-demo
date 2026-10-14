# AVD security: demo environment

A fifteen-minute live demo that shows what a secured Azure Virtual Desktop host pool looks like, then flips one setting at a time and lets the audience see what changes in a real session.

Companion code for the [gettothe.cloud](https://www.gettothe.cloud) session *Azure Virtual Desktop | Securing Your Environment*, the three-part series on the trust boundary, identity and the sessionhost, and network, data and detection. Every flip in the demo maps to a step in the attack chain from the talk: credential, token, host, elevation, data, lateral movement.

The scripts change Azure on your behalf: the RDP properties of a host pool, Terminal Services policy values on the sessionhost (through Run Command), one role assignment and one policy assignment. Point them at a lab host pool, read them before you run them, and treat this as a demo, not a production pattern. `Reset-AvdDemo` puts the RDP properties and the host values back; the role and the policy are yours to keep or remove.

This repository does not deploy the lab. It expects a host pool you already have, which keeps the demo about the settings rather than the deployment.

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

## Before you start

You need PowerShell 7.2 or later with Az.Accounts, Az.DesktopVirtualization, Az.Compute, Az.Network and Az.Resources. Az.Monitor is optional and only used for the diagnostic settings check.

The account you run it with needs to change RDP properties (Desktop Virtualization Host Pool Contributor), run commands on and restart the sessionhost (Virtual Machine Contributor), assign roles on the sessionhost resource group (User Access Administrator) and assign a policy there (Resource Policy Contributor). Owner on the lab resource groups covers all of it.

```powershell
Connect-AzAccount
cd scripts
Import-Module ./AvdSecurityDemo.psm1 -Force
Initialize-AvdDemo -SubscriptionId <subscription-id> -ResourceGroupName rg-avd-demo -HostPoolName hp-avd-demo
Show-AvdDemoState
```

`Initialize-AvdDemo` saves the host pool's current RDP properties to `scripts/.demo-state/` the first time it runs. That file is the baseline `Reset-AvdDemo` restores, so run it for the first time while the host pool is in its secured state.

## The day before

```powershell
New-AvdDemoPublicIpPolicy
Grant-AvdDemoAdminLogin -SignInName avd.poweruser@<tenant>
```

Both have a delay. A new policy assignment can take up to 30 minutes to start denying, and a role assignment needs a few minutes plus a fresh sign-in. Rehearse the demo end to end once and take a screenshot of every after-state; those are your fallbacks.

## Demo day

| When | Do | Why |
| --- | --- | --- |
| T-60 min | `Reset-AvdDemo -Restart`, then `Show-AvdDemoState` | Everything green except the poweruser line, which is the first flip |
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

Log Analytics trails a few minutes behind. If today's sign-ins aren't there yet, change `ago(2h)` to `ago(1d)` in the query and show the rehearsal.

## After the demo

```powershell
Reset-AvdDemo -Restart                                       # RDP properties and host values back to baseline
Grant-AvdDemoAdminLogin -SignInName avd.poweruser@<tenant>   # the flip 1 misconfiguration, for the next run
```

When you tear the lab down, remove the `deny-public-ip-sessionhosts` policy assignment and the poweruser's role assignment along with it.

## Things to know

Host pool RDP properties are configuration; the Terminal Services policy on the host is enforcement. Flip 2 opens the first and then closes the second, so the audience sees the restrictive one win. `Set-AvdDemoHostEnforcement -State Enforced` writes `fDisableCdm = 1` (no drive redirection), `SCClipLevel = 0` (nothing from host to client) and `CSClipLevel = 1` (plain text from client to host). Microsoft documents a restart for these settings, which is why the script restarts the host.

Clipboard direction only works when the RDP properties allow clipboard redirection in the first place, and it needs Windows 11 22H2 or later with the 2024-06 cumulative update, or Windows Server 2022 with the 2024-07 update. Disabling drive redirection on the host also blocks copying files through the clipboard.

RDP property changes reach users after a feed refresh and a new connection. Disconnecting and reconnecting keeps the old settings.

`-Watermark` adds the QR code watermark through the same registry key. Microsoft documents watermarking through Intune and Group Policy only; the registry value names here come from community scripts, so treat it as an extra and check it in your rehearsal. Once watermarking is on, only clients that support it can connect.

Conditional Access for AVD covers two moments, and `kql/avd-signins.kql` shows both: the Azure Virtual Desktop app (`9cdead84-a844-4324-93f2-b2e6bb768d07`) for the feed and the gateway, and Windows Cloud Login (`270efc09-cd0d-444b-a71f-39af4910ec45`) for the sign-in to the host with single sign-on. A policy on only one of them leaves the other one open.

## Functions

| Function | What it does | Changes Azure |
| --- | --- | --- |
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
scripts/
  AvdSecurityDemo.psm1         posture check, the flips and the reset
  Start-AvdDemo.ps1            presenter script: one step at a time, waits for you
kql/
  avd-signins.kql              both AVD authentication moments, used live
  connections.kql              WVDConnections: user, host, client IP, transport, used live
  local-admin-changes.kql      the first detection to build after the demo
  new-country-signin.kql       template: AVD sign-in from a new country
  new-egress-destination.kql   template: a host reaching somewhere its siblings never did
  fslogix-failure-rate.kql     template: profile failures by rate, not by event
PSScriptAnalyzerSettings.psd1  analyzer settings for the scripts
CHANGELOG.md
LICENSE
```

## Sources

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

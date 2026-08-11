# MeshClip Kit

MeshClip Kit configures **Tailscale + KDE Connect** for clipboard sharing and
file transfer between Windows computers that are not on the same LAN.

The repository contains deployment and diagnostic automation. Clipboard text
and transferred files never pass through GitHub.

## Current scope

- Supported and accepted: Windows 11 laptop ↔ Windows 11 desktop.
- Clipboard: online, best-effort text synchronization through KDE Connect.
- Files: KDE Connect transfer through the Tailnet (direct when possible,
  Tailscale relay otherwise).
- Android tablet: P1 target only; not part of the current acceptance gate.
- Windows pre-login clipboard and file receipt: intentionally unsupported.

"Three devices stay identical" is a user-level goal, not a strong distributed
consistency guarantee. Concurrent copies, offline devices, and Android system
clipboard restrictions require separate P1 validation.

## Security model

- Devices must first belong to the same Tailnet.
- KDE Connect pairing still requires confirmation on both devices.
- Windows inbound rules are restricted to one approved peer Tailscale IP and
  TCP/UDP ports 1714-1764.
- Existing broad KDE Connect inbound rules block configuration. They are never
  silently accepted or changed.
- Scripts never request passwords, auth keys, private keys, or access tokens.
- Diagnostics redact peer addresses and device identifiers by default.
- Received files are not automatically opened or executed.
- Do not use real passwords, API keys, OTPs, or access tokens during tests.

Read [SECURITY.md](SECURITY.md) before deployment.

## Prerequisites

- Windows 11
- PowerShell 7 (`pwsh`)
- WinGet
- A Tailscale account used through the official browser sign-in flow

The installation script uses the official WinGet packages
`Tailscale.Tailscale` and `KDE.KDEConnect`.

## Quick start

Run these commands from PowerShell 7:

```powershell
git clone https://github.com/wlyaaaaa/meshclip-kit.git
Set-Location meshclip-kit

pwsh -File .\scripts\install-windows.ps1
```

If Tailscale is not authenticated, complete the browser login and rerun the
installation script. It enables Tailscale Run Unattended and verifies KDE
Connect login startup. It also installs a silent current-user watchdog that
checks KDE Connect once per minute and restarts only the trusted indicator when
the process is absent.

After both computers appear in the same Tailnet, configure **both directions**
from an elevated PowerShell 7 window:

```powershell
# On the laptop, approve the desktop address.
pwsh -File .\scripts\configure-peer.ps1 -Peer <DESKTOP_TAILSCALE_NAME>

# On the desktop, approve the laptop address.
pwsh -File .\scripts\configure-peer.ps1 -Peer <LAPTOP_TAILSCALE_NAME>
```

If `-Peer` is omitted, the script proceeds only when it can prove that exactly
one other online Windows peer exists. If a broad non-project KDE Connect rule
is detected, configuration fails closed. Review the explicit hardening preview
before choosing to disable only those conflicting rules:

```powershell
pwsh -File .\scripts\configure-peer.ps1 -Peer <OTHER_DEVICE_TAILSCALE_NAME> -DisableBroadKdeFirewallRules -WhatIf
pwsh -File .\scripts\configure-peer.ps1 -Peer <OTHER_DEVICE_TAILSCALE_NAME> -DisableBroadKdeFirewallRules
```

Disabled rules are recorded in local state and can be re-enabled by the
explicit rollback option described under Removal.

Then confirm the KDE Connect pairing request on both devices. In KDE Connect's
Clipboard plugin settings for each peer, turn off **Including passwords**.

Run diagnostics on both computers:

```powershell
pwsh -File .\scripts\doctor.ps1 -Peer <OTHER_DEVICE_TAILSCALE_NAME>
```

On Windows, `doctor.ps1` separately verifies the watchdog login shortcut,
exactly one current-session watchdog process, and a fresh heartbeat. The
watchdog never changes Tailscale, firewall, pairing, clipboard, or file data.

See [docs/WINDOWS.md](docs/WINDOWS.md) for the complete flow and
[docs/DESKTOP_CODEX_PROMPT.md](docs/DESKTOP_CODEX_PROMPT.md) for the handoff
prompt.

## Safe preview

Mutating scripts support PowerShell's `-WhatIf` mode:

```powershell
pwsh -File .\scripts\install-windows.ps1 -WhatIf
pwsh -File .\scripts\configure-peer.ps1 -Peer example-device -WhatIf
pwsh -File .\scripts\uninstall.ps1
```

## Test

```powershell
pwsh -File .\scripts\test-repository.ps1
```

The reviewed GitHub Actions definition is stored at
`docs/examples/github-actions-test.yml`. It is intentionally inactive until the
repository owner grants GitHub `workflow` publication permission, reviews it,
and moves it to `.github/workflows/test.yml`.

## Removal

By default, removal only deletes MeshClip Kit-created firewall rules, startup
entries, watchdog runtime/status, and peer entries recorded in local state. It
does not uninstall Tailscale or KDE Connect.

```powershell
pwsh -File .\scripts\uninstall.ps1 -WhatIf
pwsh -File .\scripts\uninstall.ps1 -Apply
```

To also restore broad unmanaged KDE Connect rules that MeshClip Kit previously
disabled, preview and apply the opt-in rollback separately:

```powershell
pwsh -File .\scripts\uninstall.ps1 -RestoreDisabledBroadKdeFirewallRules
pwsh -File .\scripts\uninstall.ps1 -Apply -RestoreDisabledBroadKdeFirewallRules
```

## Documentation

- [Product baseline](docs/PRODUCT.md)
- [Windows deployment](docs/WINDOWS.md)
- [Android P1 boundary](docs/ANDROID.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

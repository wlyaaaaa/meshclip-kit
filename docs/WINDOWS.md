# Windows deployment

## 1. Install

Open PowerShell 7. If Tailscale Run Unattended is not already enabled, use an
elevated PowerShell 7 window so the preference change can be verified:

```powershell
pwsh -File .\scripts\install-windows.ps1
```

The script installs missing official WinGet packages, enables Tailscale Run
Unattended when the device is already authenticated, verifies KDE Connect's
login startup shortcut, installs a silent current-user watchdog, and starts KDE
Connect and the watchdog once. The watchdog checks every 60 seconds and starts
only the trusted KDE Connect indicator when it is absent. A current-user,
limited scheduled task invokes the hidden watchdog launcher every two minutes;
the single-instance mutex prevents duplicate watchdogs and lets Task Scheduler
restore the watchdog if its process exits.

The startup layers are intentionally independent: KDE Connect has its ordinary
login shortcut, the hidden watchdog has a login shortcut, and Task Scheduler
supervises the watchdog. None runs before Windows user sign-in. The task does
not wake the computer and Tailscale continues to use its own automatic Windows
service and vendor recovery policy.

If Tailscale needs authentication, complete the official browser flow and run
the script again. Never paste an auth key into a command or chat.

## 2. Approve each direction

After both computers appear in the same Tailnet, open an elevated PowerShell 7
window on each computer.

Laptop:

```powershell
pwsh -File .\scripts\configure-peer.ps1 -Peer <DESKTOP_NAME>
```

Desktop:

```powershell
pwsh -File .\scripts\configure-peer.ps1 -Peer <LAPTOP_NAME>
```

The scripts add the peer to KDE Connect's `customDevices` setting and create
exact-peer inbound rules for TCP/UDP 1714-1764. They accept only an online
Windows peer. When `-Peer` is omitted, exactly one other online Windows peer
must exist. They do not accept pairing.

If configuration reports broad non-project KDE Connect firewall rules, stop
and review the hardening preview:

```powershell
pwsh -File .\scripts\configure-peer.ps1 -Peer <OTHER_DEVICE_NAME> -DisableBroadKdeFirewallRules -WhatIf
```

Only after that preview is understood, rerun it without `-WhatIf`. The script
disables only the conflicting KDE Connect inbound rules, records them for
optional rollback, and still creates only the two exact-peer project rules.
Any failure rolls back changes made by that run or reports the incomplete
rollback as a blocking error.

## 3. Pair and harden

1. Open KDE Connect on both computers.
2. Confirm the same pairing identity on both devices.
3. Open the peer's Clipboard plugin settings.
4. Disable **Including passwords**.
5. Keep file receipt set to a dedicated Downloads subfolder.

## 4. Diagnose

```powershell
pwsh -File .\scripts\doctor.ps1 -Peer <OTHER_DEVICE_NAME>
```

Diagnostics deliberately omit complete peer addresses, device IDs, and private
configuration values. Do not paste raw `tailscale status --json` or KDE identity
files into a public issue or chat.

`KDE peer availability` remains `WARN` until the user has manually confirmed
the same pairing request on both computers. Device discovery alone is not
pairing evidence.

All three watchdog checks must be `PASS`: the login shortcut must still target
the project-owned `wscript.exe` wrapper, the supervisor task must retain its
exact current-user limited contract, and exactly one current-session watchdog
must have a fresh heartbeat.

## 5. Acceptance

- Copy unique non-secret text in both directions.
- Repeat 100 times with generated test strings.
- Send small, 100 MB, and 1 GB generated test files.
- Compare SHA-256 on both sides with `Get-FileHash`.
- Obtain explicit user approval before rebooting either device, then verify
  Tailscale pre-login availability and KDE Connect recovery after user login.
- Close the KDE Connect indicator once and verify that the watchdog restores
  exactly one indicator within about one minute.
- End the hidden watchdog once and verify that the supervisor restores exactly
  one watchdog within about two minutes.
- Lock the logged-in session and record observed behavior.

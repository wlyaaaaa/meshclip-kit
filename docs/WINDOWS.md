# Windows deployment

## 1. Install

On another computer, first compare the cloned repository's `git rev-parse HEAD` with the reviewed commit supplied for that deployment. Stop if they differ; do not run installation scripts from an unreviewed checkout.

Open PowerShell 7. If Tailscale Run Unattended is not already enabled, use an
elevated PowerShell 7 window so the preference change can be verified:

```powershell
pwsh -File .\scripts\install-windows.ps1
```

For the always-on main computer, the script installs missing official WinGet packages, enables Tailscale Run
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

For the on-demand secondary computer, first inspect recovery state with
`pwsh -NoProfile -File .\scripts\recover.ps1 -AsJson`. Use the reviewed full
commit ID in both commands below. Run these in the intended signed-in user's
PowerShell 7 session; if Tailscale Run Unattended still needs enabling, that
same session must be elevated. Preview first:

```powershell
pwsh -NoProfile -File .\scripts\deploy-on-demand.ps1 -ExpectedCommit <REVIEWED_40_CHARACTER_COMMIT> -WhatIf
pwsh -NoProfile -File .\scripts\deploy-on-demand.ps1 -ExpectedCommit <REVIEWED_40_CHARACTER_COMMIT>
```

This verifies the checkout commit, installs missing official components,
preserves an existing KDE pairing and exact-peer rules, removes only the
unchanged project-owned KDE login shortcut, and records on-demand mode. It
does not launch KDE or install a watchdog. If a watchdog layer or altered
startup shortcut exists, it stops for review instead of overriding it. Open
KDE Connect when clipboard sharing is wanted; quit KDE Connect when it is not.
The old heartbeat then remains stale by design. Confirm the peer and firewall
with `doctor.ps1 -Summary`; it reports an intentionally closed secondary as
healthy for the KDE runtime checks. Real transfers still require two-device
acceptance.

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

## 3. Pair

1. Open KDE Connect on both computers.
2. Confirm the same pairing identity on both devices.
3. Keep file receipt set to a dedicated Downloads subfolder.

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

On the main computer, all three watchdog checks must be `PASS`: the login shortcut must still target
the project-owned `wscript.exe` wrapper, the supervisor task must retain its
exact current-user limited contract, and exactly one current-session watchdog
must have a fresh heartbeat.

On the secondary computer, those checks pass when no watchdog layer exists;
an old or missing heartbeat is expected while KDE Connect is off.

## 5. Acceptance

- Copy unique non-secret text in both directions.
- Repeat 100 times with generated test strings.
- Send small, 100 MB, and 1 GB generated test files.
- Compare SHA-256 on both sides with `Get-FileHash`.
- Obtain explicit user approval before rebooting either device, then verify
  Tailscale pre-login availability and KDE Connect recovery after user login.
- On the main computer, close the KDE Connect indicator once and verify that
  the watchdog restores exactly one indicator within about one minute. End its
  hidden watchdog once and verify that the supervisor restores it within about
  two minutes.
- On the secondary computer, quit KDE Connect and verify that it stays closed;
  reopen it and repeat a generated text transfer.
- Lock the logged-in session and record observed behavior.

## Recovery and visible control

See [Recovery and control](RECOVERY-AND-CONTROL.md) for interrupted operations, pause/resume, strict diagnostic result meanings and the synthetic two-device acceptance guide. An already running watchdog must restart to load changed source. Pausing affects automatic recovery only; it does not remove ordinary KDE login startup or stop an existing indicator.

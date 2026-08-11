# Windows deployment

## 1. Install

Open PowerShell 7 as the normal user:

```powershell
pwsh -File .\scripts\install-windows.ps1
```

The script installs missing official WinGet packages, enables Tailscale Run
Unattended when the device is already authenticated, verifies KDE Connect's
login startup shortcut, and starts KDE Connect once.

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
exact-peer inbound rules for TCP/UDP 1714-1764. They do not accept pairing.

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

## 5. Acceptance

- Copy unique non-secret text in both directions.
- Repeat 100 times with generated test strings.
- Send small, 100 MB, and 1 GB generated test files.
- Compare SHA-256 on both sides with `Get-FileHash`.
- Reboot each device and verify the documented startup states.
- Lock the logged-in session and record observed behavior.

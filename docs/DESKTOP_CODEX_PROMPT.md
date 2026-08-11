# Desktop Codex handoff prompt

Replace the placeholders before sending this prompt to Codex on the desktop.

```text
You are configuring a Windows 11 desktop for MeshClip Kit.

Repository:
https://github.com/wlyaaaaa/meshclip-kit.git

Laptop Tailscale name:
[LAPTOP_TAILSCALE_NAME]

Goal:
Install and verify Tailscale + KDE Connect for bidirectional clipboard and file
transfer with the laptop, without exposing credentials or unrelated services.

Requirements:

1. Clone the repository into the current workspace. Read README.md, SECURITY.md,
   docs/WINDOWS.md, and every PowerShell script before executing it.
2. Use PowerShell 7. Install missing dependencies only through trusted official
   package sources. Preserve existing application and network configuration.
3. First run scripts/install-windows.ps1 with -WhatIf, review its proposed
   actions, then run it normally.
4. Tailscale authentication must use the official browser flow. Pause for me
   when interaction is required. Never request, print, or persist a password,
   auth key, access token, private key, or certificate.
5. Confirm the desktop and laptop appear in the same Tailnet. Do not print the
   complete device list or complete Tailscale IPs in chat.
6. From an elevated PowerShell 7 window, first run
   scripts/configure-peer.ps1 -Peer [LAPTOP_TAILSCALE_NAME] -WhatIf, then run it
   normally. Firewall access must be limited to the laptop's exact Tailscale IP
   and TCP/UDP 1714-1764. Do not create broad public or whole-Tailnet-range
   rules.
7. Report the desktop's Tailscale device name to me in a locally visible,
   redacted-safe way so the laptop can independently run configure-peer for the
   desktop. Both directions are required.
8. Ask me to confirm KDE Connect pairing on both computers. Do not accept the
   request silently. After pairing, remind me to disable the peer Clipboard
   option "Including passwords" on both computers.
9. Run scripts/doctor.ps1 -Peer [LAPTOP_TAILSCALE_NAME]. Validate connectivity,
   KDE Connect status, login startup, exact-peer firewall rules, bidirectional
   non-secret text, and a generated test file with matching SHA-256.
10. Do not modify unrelated files, VPNs, routes, firewall rules, startup items,
    or user settings. Do not use real secrets as test clipboard content.
11. Finish with versions, each acceptance result, any required laptop-side
    action, failures, and rollback guidance. Redact account names, full IPs,
    device IDs, and private paths from the report.
```

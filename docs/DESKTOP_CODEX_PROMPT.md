# Desktop Codex handoff prompt

Supply the expected reviewed commit out of band, then send the following prompt
to Codex on the second Windows computer.

```text
You are deploying and accepting MeshClip Kit on the other Windows 11 computer.

Repository:
https://github.com/wlyaaaaa/meshclip-kit

Expected reviewed main commit:
[EXPECTED_MAIN_COMMIT]

1. Clone into the approved workspace. Immediately run git rev-parse HEAD; it
   must equal the supplied commit or you must stop before running scripts. A
   single Git command may bypass a demonstrably stale local proxy, but do not
   change global Git, Windows, VPN, route, or proxy settings.
2. Fully read README.md, SECURITY.md, docs/WINDOWS.md,
   docs/TROUBLESHOOTING.md, and every PowerShell script you may execute.
3. Use PowerShell 7. Run install-windows.ps1 -WhatIf, review it, then run the
   same script normally. Use only Tailscale's official browser login; never
   request, print, store, or generate credentials, auth keys, tokens, private
   keys, or certificates. Verify the project-owned silent KDE Connect watchdog
   login shortcut, low-privilege supervisor task, one current-session process,
   and a fresh heartbeat.
4. Inspect tailscale status --json only locally. If exactly one other online
   Windows peer exists, use it. Otherwise stop for explicit local selection.
   Never print the device list, full address, device ID, or private DNS name.
5. In elevated PowerShell 7, preview configure-peer.ps1 for the exact peer. If
   broad non-project KDE Connect inbound rules block the run, separately review
   the -DisableBroadKdeFirewallRules -WhatIf plan before using that switch
   normally. Final enabled access must be exactly the peer's Tailscale IPv4,
   Tailscale interface, kdeconnectd.exe, TCP/UDP 1714-1764; never Any,
   LocalSubnet, public networks, or a whole Tailnet range.
6. Open KDE Connect and ask the user to confirm the same pairing request on
   both computers. Never accept silently. Then ask the user to disable
   "Including passwords" in the peer Clipboard plugin on both computers.
7. Run doctor.ps1 for the exact peer. Require the Tailscale Windows service,
   KDE Connect login startup, and KDE Connect watchdog checks to pass. Broad
   firewall access is FAIL; manual pairing/password checks may remain WARN
   until the user confirms them.
8. Only while the computers are on different LANs, test generated non-secret
   mixed Chinese/English/Emoji/URL text in both directions, 100 numbered text
   copies without echo loops, and generated small, 100,000,000-byte, and
   1,000,000,000-byte files in both directions. Never open or execute received
   files. Compare byte lengths and SHA-256 on both sides.
9. Obtain explicit approval before either reboot. After reboot, verify
   Tailscale's pre-login state and KDE Connect recovery after user login.
10. Do not modify unrelated files, VPNs, routes, proxies, firewall rules,
    startup items, or user settings. Do not put raw JSON, inventories,
    addresses, clipboard contents, file contents, or KDE identity material in
    GitHub.
11. Report in Simplified Chinese: versions, repository commit, PASS/FAIL for
    every item, sanitized failure evidence, remaining actions on the other
    computer, and rollback commands. Redact every identity and address.

Product boundary: Windows laptop and desktop only. KDE Connect provides
best-effort online single-writer synchronization, not strong consistency;
simultaneous copies, offline devices, and Android background clipboard are not
guaranteed.
```

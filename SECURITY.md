# Security policy

## Supported scope

Security fixes currently target the latest repository version on Windows 11.

## Sensitive data rules

Never commit or attach:

- Tailscale auth keys, access tokens, or complete device inventories.
- KDE Connect `privateKey.pem`, `certificate.pem`, or per-device credentials.
- Complete Tailscale IP addresses or private machine names in public reports.
- Clipboard text, transferred files, passwords, API keys, OTPs, or secrets.

Local state is written under `%LOCALAPPDATA%\MeshClipKit`. KDE Connect identity
files remain under `%LOCALAPPDATA%\kdeconnect` and are never copied by these
scripts.

## Pairing and firewall policy

- Pairing must be confirmed by the user on both devices.
- `configure-peer.ps1` accepts only a peer already visible in the current
  Tailnet; arbitrary public addresses are rejected.
- Each approved peer receives two inbound rules: TCP and UDP 1714-1764.
- Rules are scoped to that peer's exact Tailscale IPv4 address.
- Outbound rules and public-network-wide allow rules are not created.
- Every Windows device must independently approve every intended peer.

## Clipboard warning

Clipboard content may contain passwords, API keys, OTPs, session cookies, or
other secrets. KDE Connect can only identify password-manager content when the
source application marks it correctly. After pairing, disable the Clipboard
plugin option **Including passwords** for every peer. This reduces risk but is
not a complete secret-detection mechanism.

Do not use real secrets for acceptance testing.

## Reporting a vulnerability

Do not open a public issue containing secrets, device identifiers, or private
logs. Send a minimal reproduction with all identities and addresses removed.

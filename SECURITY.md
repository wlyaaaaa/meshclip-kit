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

The Windows watchdog is a current-user, login-scoped recovery process. Its
first launcher is `wscript.exe`, so background startup does not require a
console window. It checks only whether the trusted KDE Connect indicator is
running in the same interactive session. Its heartbeat contains only a schema,
timestamp, bounded status, and restart count; it does not read clipboard data,
device identity, addresses, Tailscale state, files, or firewall configuration.

## Pairing and firewall policy

- Pairing must be confirmed by the user on both devices.
- `configure-peer.ps1` accepts only a peer already visible in the current
  Tailnet, online, and reported as Windows; arbitrary public addresses,
  offline peers, and non-Windows peers are rejected.
- Automatic selection is permitted only when exactly one other online Windows
  peer exists. Otherwise the user must provide an exact peer name.
- Each approved peer receives two inbound rules: TCP and UDP 1714-1764.
- Rules are validated by exact set equality for protocol, port, peer Tailscale
  IPv4, KDE daemon path, and Tailscale interface. A rule that also contains
  `Any`, another address, port, program, or interface is rejected.
- Outbound rules and public-network-wide allow rules are not created.
- Broad non-project inbound rules targeting KDE Connect are a blocking
  diagnostic. They are changed only when the operator explicitly supplies
  `-DisableBroadKdeFirewallRules`; the exact disabled rule identities are kept
  only in ignored local state for optional rollback.
- Any remaining enabled non-project KDE Connect inbound rule still blocks final
  acceptance, even if it appears narrow; the hardening switch does not take
  ownership of such unrelated rules.
- Every Windows device must independently approve every intended peer.

## Startup and watchdog policy

- Tailscale remains an automatic Windows service using its vendor-provided
  failure-recovery actions. MeshClip Kit does not replace that service or run a
  second privileged network watchdog.
- The hidden watchdog and its Task Scheduler supervisor run only for the current
  signed-in user. The supervisor uses `Interactive` logon type and `Limited`
  run level; neither component runs as `SYSTEM` or with highest privileges.
- The supervisor's only action is the exact project-owned `wscript.exe` wrapper.
  The wrapper starts the exact watchdog script, and the watchdog starts only
  the trusted `kdeconnect-indicator.exe` when it is absent.
- The watchdog does not inspect or persist clipboard or file content. Its local
  heartbeat contains only a schema, timestamp, bounded status, and restart
  count.
- Registration, diagnosis, and removal require the full exact task contract.
  A pre-existing or subsequently changed same-named task is not overwritten or
  deleted.
- The task neither wakes a sleeping device nor provides pre-login receipt. Its
  two-minute trigger supervises the watchdog only while this user is signed in.

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

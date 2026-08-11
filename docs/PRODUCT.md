# Product baseline

## Decision

The Windows MVP uses Tailscale for private cross-network reachability and KDE
Connect for text clipboard sharing and file transfer. A public GitHub
repository distributes only scripts and documentation.

## Acceptance boundary

Current acceptance covers only a Windows 11 laptop and desktop on different
networks:

- Tailscale is online and configured to run unattended.
- KDE Connect starts after Windows user login.
- A silent current-user watchdog restores the trusted KDE Connect indicator if
  that process exits during the logged-in session.
- Text copied on either computer becomes available on the other computer.
- Files transfer in both directions and match SHA-256 checksums.
- Firewall access is limited to the explicitly approved peer.
- Unknown and unpaired devices cannot exchange data.

Android is P1. The target experience is that, after the tablet connects to
Tailscale and starts KDE Connect, clipboard updates from either Windows device
reach the other online devices. Android-originated automatic clipboard capture,
offline catch-up, concurrent writes, and background behavior are not claimed
until separately validated.

## Consistency definition

KDE Connect does not provide a strongly consistent replicated clipboard. The
MVP promises online best-effort synchronization under ordinary single-writer
use. It does not promise deterministic ordering for simultaneous copies or
replay to devices that were offline.

## Non-goals

- Windows pre-login clipboard access or file receipt.
- Image clipboard synchronization; images are transferred as files.
- Offline queues, custom relay servers, or file resumability.
- Automatic Android coexistence with another system VPN.
- Silent acceptance of KDE Connect pairing requests.

## Success criteria

1. Clipboard latency is normally under two seconds.
2. 100 sequential text copies do not create an echo loop.
3. Test files up to 1 GB arrive with matching SHA-256.
4. Reboot restores Tailscale before login and KDE Connect after login.
5. Repository and diagnostics contain no secrets or private identities.

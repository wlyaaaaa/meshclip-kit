# Android tablet: P1 boundary

Android is not part of the current acceptance gate.

## Target workflow

1. Disconnect any other active system VPN if necessary.
2. Connect the tablet to the same Tailnet with Tailscale.
3. Start KDE Connect and keep it allowed to run in the background.
4. Pair the tablet with each approved Windows computer.
5. Validate PC-to-tablet clipboard updates and file sharing.

The user is willing to grant foreground-service, accessibility, startup, and
battery-exemption permissions in a future phase. Those permissions do not
automatically grant Android's system-only background clipboard capability.
Android-originated automatic clipboard capture therefore remains a technical
spike rather than a committed current feature.

## Samsung reliability settings to validate later

- Allow Tailscale and KDE Connect to run in the background.
- Set battery use to Unrestricted where available.
- Exclude both apps from sleeping/deep-sleeping app lists.
- Keep KDE Connect notifications enabled.
- On Android 14+, add KDE Connect's Send clipboard quick-settings tile.

## Networking limitation

Android generally permits only one active VPN service. The current design uses
manual switching when an overseas VPN and Tailscale cannot coexist. Exit nodes,
custom HTTPS relays, Shizuku/ADB, root, and a custom input method are explicitly
outside the MVP.

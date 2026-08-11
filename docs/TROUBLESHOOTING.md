# Troubleshooting

## Tailscale is installed but the peer is absent

- Confirm both devices use the intended Tailnet.
- Complete browser authentication if `tailscale status` reports a login need.
- Run `tailscale status` locally; do not publish the raw output.
- Verify the device is awake and not expired in the Tailscale admin console.

## KDE Connect cannot discover the peer

- Run `configure-peer.ps1` on both computers, not only one.
- Confirm each script selected the intended peer.
- Confirm the exact-peer TCP and UDP 1714-1764 rules exist.
- Restart KDE Connect or run `kdeconnect-cli --refresh`.

## Clipboard does not update

- Confirm both users are logged in and KDE Connect is running.
- Confirm the Clipboard plugin is enabled for the peer.
- Test plain text first; image clipboard formats are unsupported by this MVP.
- Avoid simultaneous copies while diagnosing ordering issues.

## File transfer fails

- Verify the destination device is online and paired.
- Confirm the receiving directory is writable and has free space.
- Retry after a network interruption; resumability is not promised.
- Compare SHA-256 before treating a transferred file as accepted.

## Android does not send copied text automatically

- This is expected on standard Android 10 and later when KDE Connect is in the
  background.
- Use KDE Connect's **Send clipboard** action or quick-settings tile.
- Granting ordinary app permissions, accessibility, unrestricted battery, and
  autostart access does not remove the operating-system clipboard restriction.

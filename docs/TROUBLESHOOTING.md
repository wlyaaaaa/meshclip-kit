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

## Configuration stops on broad KDE firewall rules

- Treat this as a security block, not a warning to ignore.
- Run `configure-peer.ps1` with `-DisableBroadKdeFirewallRules -WhatIf` and
  verify that the plan only disables non-project inbound rules targeting the
  trusted KDE Connect daemon.
- Rerun without `-WhatIf` only after reviewing the plan. Disabled rule
  identities remain in ignored local state and are not printed in reports.
- To restore them during rollback, first preview
  `uninstall.ps1 -RestoreDisabledBroadKdeFirewallRules`, then add `-Apply`.

## An interrupted transaction is reported

- Stop making configuration changes and run `doctor.ps1` locally.
- Preserve `%LOCALAPPDATA%\MeshClipKit` and KDE config backups while reviewing
  the last operation; do not delete unrelated firewall rules or KDE identity
  files.
- If automatic rollback reported an incomplete component, repair only that
  named component before rerunning configuration.

## Clipboard does not update

- Confirm both users are logged in and KDE Connect is running.
- Confirm the Clipboard plugin is enabled for the peer.
- Test plain text first; image clipboard formats are unsupported by this MVP.
- Avoid simultaneous copies while diagnosing ordering issues.

## KDE Connect stops after it was working

- Run `doctor.ps1` and check both watchdog rows.
- Rerun `install-windows.ps1 -WhatIf`, review the watchdog shortcut/start plan,
  then run it normally. The installer refuses to overwrite a changed shortcut.
- A healthy watchdog uses one hidden current-session PowerShell process and a
  fresh status heartbeat. It does not repair Tailscale, firewall, pairing, or
  plugin settings.
- If the indicator repeatedly exits, treat that application failure separately
  instead of shortening the watchdog interval or creating duplicate startup
  tasks.

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

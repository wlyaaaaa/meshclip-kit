#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch] $Apply,
    [switch] $RestoreTailscaleMode,
    [switch] $RestoreDisabledBroadKdeFirewallRules
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MeshClip.Common.psm1') -Force

$paths = Get-MeshClipPaths
if (-not (Test-Path -LiteralPath $paths.StatePath -PathType Leaf)) {
    throw 'No valid MeshClip Kit state file exists. Refusing to guess which resources to remove.'
}
$state = Get-MeshClipState
if ($state.pendingTransaction) {
    throw 'An interrupted configuration transaction is recorded. Run doctor.ps1 and review the machine before uninstalling.'
}

Write-Host 'Removal plan:'
Write-Host "- Remove $(@($state.addedPeers).Count) MeshClip Kit-added KDE custom peer entries."
Write-Host "- Remove $(@($state.firewallRules).Count) recorded project-owned firewall rules."
Write-Host "- Remove the login shortcut only if MeshClip Kit created it and it is unchanged."
if ($state.watchdogShortcutCreated) {
    Write-Host '- Stop the current-session watchdog and remove its login shortcut only if it is unchanged.'
}
if ($state.watchdogTaskCreated) {
    Write-Host '- Remove the low-privilege watchdog supervisor task only if it is unchanged.'
}
if ($RestoreDisabledBroadKdeFirewallRules -and @($state.disabledBroadFirewallRules).Count -gt 0) {
    Write-Host "- Re-enable $(@($state.disabledBroadFirewallRules).Count) broad unmanaged KDE Connect firewall rules previously disabled by MeshClip Kit."
}
if ($RestoreTailscaleMode -and $state.tailscaleModeChanged) {
    Write-Host '- Restore Tailscale unattended mode to disabled.'
}
Write-Host '- Keep Tailscale, KDE Connect, pairings, certificates, private keys, and config backups.'

if (-not $Apply) {
    Write-Host ''
    Write-Host 'Preview only. Rerun with -Apply after reviewing this plan; -WhatIf remains supported.'
    return
}
if ((@($state.firewallRules).Count -gt 0 -or
    ($RestoreDisabledBroadKdeFirewallRules -and @($state.disabledBroadFirewallRules).Count -gt 0)) -and
    -not (Test-MeshClipAdministrator)) {
    throw 'Open PowerShell 7 as Administrator before applying removal.'
}

$lock = Enter-MeshClipOperationLock
try {
    $remainingPeers = [Collections.Generic.List[string]]::new()
    foreach ($address in @($state.addedPeers)) { $remainingPeers.Add([string]$address) }
    foreach ($address in @($state.addedPeers)) {
        $redacted = ConvertTo-MeshClipRedactedAddress -Address $address
        if ($PSCmdlet.ShouldProcess('KDE Connect customDevices', "Remove project-added peer $redacted")) {
            $result = Write-MeshClipKdeConfigChange -Action Remove -Address $address
            $remainingPeers.Remove([string]$address) | Out-Null
            if ($result.Changed) {
                Write-Host "[PASS] Removed one project-added peer at $redacted."
            }
        }
    }
    $state.addedPeers = @($remainingPeers)

    if (@($state.firewallRules).Count -gt 0 -and $PSCmdlet.ShouldProcess('Windows Firewall', 'Remove recorded MeshClip Kit rules')) {
        Remove-MeshClipFirewallRules -Names @($state.firewallRules)
        $state.firewallRules = @()
        Write-Host '[PASS] Removed recorded project-owned firewall rules.'
    }

    if ($state.startupShortcutCreated) {
        $startup = Get-MeshClipStartupInfo
        if ($startup.Exists -and $startup.OwnedAndUnchanged) {
            if ($PSCmdlet.ShouldProcess($paths.StartupShortcut, 'Remove MeshClip Kit-created startup shortcut')) {
                Remove-Item -LiteralPath $paths.StartupShortcut -Force
                $state.startupShortcutCreated = $false
                Write-Host '[PASS] Removed the project-created login shortcut.'
            }
        }
        elseif ($startup.Exists) {
            Write-Warning 'Startup shortcut changed after setup; it was preserved.'
        }
        else {
            $state.startupShortcutCreated = $false
        }
    }

    $watchdogRemovalBlocked = $false
    if ($state.watchdogTaskCreated) {
        $watchdogTask = Get-MeshClipWatchdogTaskInfo
        if ($watchdogTask.Exists -and $watchdogTask.OwnedAndUnchanged) {
            if ($PSCmdlet.ShouldProcess('KDE Connect watchdog supervisor task', 'Remove the project-owned low-privilege task')) {
                Remove-MeshClipWatchdogTask | Out-Null
                $state.watchdogTaskCreated = $false
                Write-Host '[PASS] Removed the project-created watchdog supervisor task.'
            }
            else {
                $watchdogRemovalBlocked = $true
            }
        }
        elseif ($watchdogTask.Exists) {
            $watchdogRemovalBlocked = $true
            Write-Warning 'The watchdog supervisor task changed after setup; all watchdog resources were preserved.'
        }
        else {
            $state.watchdogTaskCreated = $false
        }
    }

    if ($state.watchdogShortcutCreated -and $watchdogRemovalBlocked) {
        Write-Warning 'Watchdog startup and runtime were preserved because the supervisor task was not removed.'
    }
    elseif ($state.watchdogShortcutCreated) {
        $watchdogStartup = Get-MeshClipWatchdogStartupInfo
        if ($watchdogStartup.Exists -and -not $watchdogStartup.OwnedAndUnchanged) {
            Write-Warning 'Watchdog startup shortcut changed after setup; it and the running watchdog were preserved.'
        }
        elseif ($PSCmdlet.ShouldProcess('MeshClip Kit KDE watchdog', 'Stop the exact current-session process and remove project-owned startup/status files')) {
            Stop-MeshClipWatchdogProcesses
            if ($watchdogStartup.Exists) {
                Remove-Item -LiteralPath $paths.WatchdogShortcut -Force
            }
            if (Test-Path -LiteralPath $paths.WatchdogStatusPath -PathType Leaf) {
                Remove-Item -LiteralPath $paths.WatchdogStatusPath -Force
            }
            $state.watchdogShortcutCreated = $false
            Write-Host '[PASS] Removed the project-owned KDE Connect watchdog.'
        }
    }

    if ($RestoreDisabledBroadKdeFirewallRules -and
        @($state.disabledBroadFirewallRules).Count -gt 0 -and
        $PSCmdlet.ShouldProcess('Windows Firewall', 'Re-enable recorded unmanaged KDE Connect rules')) {
        Enable-MeshClipDisabledUnmanagedKdeFirewallRules -Names @($state.disabledBroadFirewallRules)
        $state.disabledBroadFirewallRules = @()
        Write-Host '[PASS] Restored the recorded unmanaged firewall rules to their prior enabled state.'
    }

    if ($RestoreTailscaleMode -and $state.tailscaleModeChanged) {
        $tailscale = Get-MeshClipTrustedCommand -Name tailscale
        if ($tailscale -and $PSCmdlet.ShouldProcess('Tailscale', 'Disable Run Unattended without resetting other preferences')) {
            Invoke-MeshClipExternal -FilePath $tailscale -ArgumentList @('set', '--unattended=false') | Out-Null
            $state.tailscaleModeChanged = $false
            Write-Host '[PASS] Restored the previous unattended-mode intent.'
        }
    }

    if (-not $WhatIfPreference) {
        Save-MeshClipState -State $state
    }
}
finally {
    Exit-MeshClipOperationLock -Lock $lock
}

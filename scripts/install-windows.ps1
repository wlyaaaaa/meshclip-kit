#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param([switch]$SkipTailscaleUnattended, [switch]$SkipKdeStartup,
    [switch]$SkipKdeWatchdog, [switch]$NoLaunchKdeConnect, [switch]$AsJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MeshClip.Common.psm1') -Force
if (-not $IsWindows -or [Environment]::OSVersion.Version.Build -lt 22000) { throw 'MeshClip requires Windows 11.' }
if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { throw 'Run setup as the intended signed-in Windows user, not SYSTEM.' }
$lock = Enter-MeshClipOperationLock
$notes = [Collections.Generic.List[string]]::new()
$changed = 0
try {
    $state = Get-MeshClipState
    Assert-MeshClipNoPendingTransaction -State $state
    # Check conflicts before installing packages or changing preferences.
    if (-not $SkipKdeStartup) {
        $startup = Get-MeshClipStartupInfo
        if ($startup.Exists -and -not $startup.Matches) { throw 'A different KDE login shortcut exists; it was preserved.' }
    }
    if (-not $SkipKdeWatchdog) {
        $watchdogStartup = Get-MeshClipWatchdogStartupInfo
        if ($watchdogStartup.Exists -and -not $watchdogStartup.OwnedAndUnchanged) { throw 'A different watchdog startup shortcut exists; it was preserved.' }
        $watchdogTask = Get-MeshClipWatchdogTaskInfo
        if ($watchdogTask.Exists -and -not $watchdogTask.Compliant) { throw 'A different watchdog supervisor task exists; it was preserved.' }
    }
    $packages = @(
        @{ name = 'Tailscale'; id = 'Tailscale.Tailscale'; installed = [bool](Get-MeshClipTrustedCommand -Name tailscale) },
        @{ name = 'KDE Connect'; id = 'KDE.KDEConnect'; installed = [bool](Get-MeshClipKdeInstallRoot) }
    )
    foreach ($package in $packages) {
        if ($package.installed) { continue }
        if ($PSCmdlet.ShouldProcess($package.name, 'Install official package; package installation is retained on integration failure')) {
            $winget = Get-MeshClipTrustedCommand -Name winget
            if (-not $winget) { throw 'WinGet is required only for missing packages. Install App Installer and rerun.' }
            Invoke-MeshClipExternal -FilePath $winget -ArgumentList @('install','--id',$package.id,'--exact','--source','winget','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -TimeoutSeconds 600 | Out-Null
            $notes.Add("Installed $($package.name). Third-party packages are intentionally retained if later integration fails.")
        }
    }
    $plan = [Collections.Generic.List[object]]::new()
    $tailscale = Get-MeshClipTrustedCommand -Name tailscale
    if ($tailscale) {
        $status = Get-MeshClipTailscaleStatus
        if ($status.BackendState -ne 'Running' -or -not $status.SelfOnline) { $notes.Add('Tailscale authentication/connection still requires attention.') }
        elseif (-not $SkipTailscaleUnattended) {
            $prefs = Get-MeshClipTailscalePreferences
            if (-not $prefs) { throw 'Tailscale preference is unknown; no integration change made.' }
            if (-not $prefs.ForceDaemon) { $plan.Add(@{ kind = 'TailscaleMode'; data = @{ before = $false }; flag = 'tailscaleModeChanged' }) }
        }
    }
    $indicator = Get-MeshClipKdeExecutable -Kind indicator
    if ($indicator) {
        if (-not $SkipKdeStartup -and -not (Get-MeshClipStartupInfo).Exists) { $plan.Add(@{ kind = 'ShortcutCreate'; data = @{ type = 'startup' }; flag = 'startupShortcutCreated' }) }
        if (-not $SkipKdeWatchdog) {
            if (-not (Get-MeshClipWatchdogStartupInfo).Exists) { $plan.Add(@{ kind = 'ShortcutCreate'; data = @{ type = 'watchdog' }; flag = 'watchdogShortcutCreated' }) }
            if (-not (Get-MeshClipWatchdogTaskInfo).Exists) { $plan.Add(@{ kind = 'WatchdogTaskCreate'; data = @{}; flag = 'watchdogTaskCreated' }) }
        }
    } else { $notes.Add('KDE Connect is unavailable; install it before integration can complete.') }
    try {
        foreach ($item in $plan) {
            if (-not $PSCmdlet.ShouldProcess('Current-user MeshClip integration', $item.kind + ':' + $item.flag)) { continue }
            if ($item.kind -eq 'TailscaleMode' -and -not (Test-MeshClipAdministrator)) { throw 'Enabling unattended mode requires an elevated window for this same Windows user.' }
            if (-not $state.pendingTransaction) { Start-MeshClipTransaction -State $state -Operation 'install' }
            $step = Add-MeshClipTransactionStep -State $state -Kind $item.kind -Data $item.data
            switch ($item.kind) {
                'TailscaleMode' {
                    Invoke-MeshClipExternal -FilePath $tailscale -ArgumentList @('set','--unattended=true') | Out-Null
                    $readback = Get-MeshClipTailscalePreferences
                    if (-not $readback -or -not $readback.ForceDaemon) { throw 'Unattended mode did not verify.' }
                }
                'ShortcutCreate' {
                    if ($item.data.type -eq 'startup') { New-MeshClipStartupShortcut | Out-Null; $readback = Get-MeshClipStartupInfo }
                    else { New-MeshClipWatchdogStartupShortcut | Out-Null; $readback = Get-MeshClipWatchdogStartupInfo }
                    if (-not $readback.OwnedAndUnchanged) { throw 'Startup shortcut did not verify.' }
                }
                'WatchdogTaskCreate' {
                    New-MeshClipWatchdogTask | Out-Null
                    if (-not (Get-MeshClipWatchdogTaskInfo).Compliant) { throw 'Supervisor task did not verify.' }
                }
            }
            $state.($item.flag) = $true
            Complete-MeshClipTransactionStep -State $state -Step $step
            $changed++
        }
        Complete-MeshClipTransaction -State $state
    }
    catch {
        $cause = $_
        if ($state.pendingTransaction) {
            $recovery = Repair-MeshClipTransaction -State $state
            if ($recovery.status -ne 'recovered') { throw 'Integration failed; incomplete recovery remains recorded. Run recover.ps1.' }
        }
        throw $cause
    }
    # Launch only after durable integration commit; never hide a launch failure
    # behind a successful configuration result. Session 0 cannot launch a tray.
    if (-not $NoLaunchKdeConnect -and -not $WhatIfPreference -and $indicator) {
        if ((Get-Process -Id $PID).SessionId -eq 0) { $notes.Add('Configuration is committed. Tray/watchdog launch must occur in the interactive user session.') }
        else {
            try {
                if (-not $SkipKdeWatchdog) {
                    if ((Get-MeshClipWatchdogControl).paused) { $notes.Add('Watchdog is deliberately paused; no automatic launch requested.') }
                    elseif ($PSCmdlet.ShouldProcess('MeshClip watchdog', 'Launch in this user session')) {
                        Start-MeshClipWatchdog | Out-Null
                        Start-Sleep -Milliseconds 800
                        if (-not (Get-MeshClipWatchdogProcessInfo).Running) { throw 'Watchdog launch did not verify.' }
                    }
                }
                elseif (-not @(Get-Process -Name kdeconnect-indicator -ErrorAction SilentlyContinue | Where-Object SessionId -eq (Get-Process -Id $PID).SessionId).Count -and $PSCmdlet.ShouldProcess('KDE Connect', 'Launch indicator')) {
                    Start-Process -FilePath $indicator
                }
            } catch { $notes.Add('Configuration committed, but user-session launch could not be verified. Use the control center; no configuration rollback was implied.') }
        }
    }
    $result = [pscustomobject]@{ schema = 'meshclip.install.v1'; status = if ($WhatIfPreference) { 'preview' } elseif ($notes.Count) { 'needs_attention' } else { 'configured' }; integration_changes = $changed; notes = @($notes); business_acceptance = 'not_tested' }
    if ($AsJson) { $result | ConvertTo-Json -Depth 6 } else { $result | Format-List; Write-Host 'Next: configure the opposite peer, confirm pairing, then use acceptance.ps1. Control center: control-center.ps1.' }
}
finally { Exit-MeshClipOperationLock -Lock $lock }

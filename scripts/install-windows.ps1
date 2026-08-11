#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch] $SkipTailscaleUnattended,
    [switch] $SkipKdeStartup,
    [switch] $NoLaunchKdeConnect
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MeshClip.Common.psm1') -Force

if (-not $IsWindows) {
    throw 'MeshClip Kit Windows setup can only run on Windows.'
}
if ([Environment]::OSVersion.Version.Build -lt 22000) {
    throw 'The current MVP supports Windows 11 only.'
}
$lock = Enter-MeshClipOperationLock
try {
    $state = Get-MeshClipState
    $stateChanged = $false
    $unattendedEnabledThisRun = $false
    $startupCreatedThisRun = $false
    $winget = Get-MeshClipTrustedCommand -Name winget
    if (-not $winget) {
        throw 'WinGet is required. Install or repair Windows App Installer first.'
    }

    $packages = @(
        [pscustomobject]@{
            Name      = 'Tailscale'
            Id        = 'Tailscale.Tailscale'
            Installed = [bool](Get-MeshClipTrustedCommand -Name tailscale)
        },
        [pscustomobject]@{
            Name      = 'KDE Connect'
            Id        = 'KDE.KDEConnect'
            Installed = [bool](Get-MeshClipKdeInstallRoot)
        }
    )

    foreach ($package in $packages) {
        if ($package.Installed) {
            Write-Host "[PASS] $($package.Name) is already installed; no upgrade was requested."
            continue
        }
        if ($PSCmdlet.ShouldProcess($package.Name, "Install exact WinGet package $($package.Id) from source winget")) {
            Invoke-MeshClipExternal -FilePath $winget -ArgumentList @(
                'install', '--id', $package.Id, '--exact', '--source', 'winget',
                '--silent', '--accept-package-agreements', '--accept-source-agreements',
                '--disable-interactivity'
            ) | Out-Null
            Write-Host "[PASS] Installed $($package.Name)."
        }
    }

    $tailscale = Get-MeshClipTrustedCommand -Name tailscale
    if ($tailscale) {
        $status = $null
        try {
            $status = Get-MeshClipTailscaleStatus
        }
        catch {
            throw 'Tailscale status could not be verified safely. Raw command output was suppressed.'
        }
        if ($status.BackendState -ne 'Running' -or -not $status.SelfOnline) {
            Write-Warning 'Tailscale is installed but not online. Complete the official browser login, then rerun this script.'
        }
        elseif (-not $SkipTailscaleUnattended) {
            $prefs = Get-MeshClipTailscalePreferences
            if (-not $prefs) {
                throw 'Tailscale Run Unattended could not be verified; setup stopped without changing the preference.'
            }
            if (-not $prefs.ForceDaemon) {
                if (-not (Test-MeshClipAdministrator)) {
                    throw 'Open PowerShell 7 as Administrator to enable Tailscale Run Unattended, then rerun setup.'
                }
                if ($PSCmdlet.ShouldProcess('Tailscale', 'Enable Run Unattended without resetting other preferences')) {
                    Invoke-MeshClipExternal -FilePath $tailscale -ArgumentList @('set', '--unattended=true') | Out-Null
                    $state.tailscaleModeChanged = $true
                    $stateChanged = $true
                    $unattendedEnabledThisRun = $true
                    Write-Host '[PASS] Enabled Tailscale Run Unattended.'
                }
            }
            else {
                Write-Host '[PASS] Tailscale Run Unattended is already enabled.'
            }
        }

        if ($status.BackendState -eq 'Running') {
            try {
                $shield = Invoke-MeshClipExternal -FilePath $tailscale -ArgumentList @('get', 'shields-up')
                if (($shield.Output -join '').Trim() -eq 'true') {
                    Write-Warning 'Tailscale shields-up is enabled. Incoming KDE Connect traffic will be blocked; change this manually if intentional.'
                }
            }
            catch {
                Write-Warning 'Could not verify the Tailscale shields-up setting.'
            }
        }
    }

    $indicator = Get-MeshClipKdeExecutable -Kind indicator
    if ($indicator) {
        if (-not $SkipKdeStartup) {
            $startup = Get-MeshClipStartupInfo
            if ($startup.Exists -and $startup.Matches) {
                Write-Host '[PASS] KDE Connect login startup already points to the trusted indicator executable.'
            }
            elseif ($PSCmdlet.ShouldProcess('Current user startup folder', 'Create KDE Connect login startup shortcut')) {
                $result = New-MeshClipStartupShortcut
                if ($result.Created) {
                    $state.startupShortcutCreated = $true
                    $stateChanged = $true
                    $startupCreatedThisRun = $true
                }
                Write-Host '[PASS] KDE Connect login startup is configured.'
            }
        }

        if (-not $NoLaunchKdeConnect -and -not (Get-Process -Name kdeconnect-indicator -ErrorAction SilentlyContinue)) {
            if ($PSCmdlet.ShouldProcess('KDE Connect', 'Start the user tray indicator once')) {
                Start-Process -FilePath $indicator
                Write-Host '[PASS] Started KDE Connect indicator.'
            }
        }
    }
    else {
        Write-Warning 'KDE Connect is not yet available. If -WhatIf was used, this is expected.'
    }

    if ($stateChanged -and -not $WhatIfPreference) {
        try {
            Save-MeshClipState -State $state
        }
        catch {
            $rollbackErrors = [Collections.Generic.List[string]]::new()
            if ($startupCreatedThisRun) {
                try {
                    $startup = Get-MeshClipStartupInfo
                    if (-not $startup.OwnedAndUnchanged) { throw 'shortcut changed' }
                    Remove-Item -LiteralPath (Get-MeshClipPaths).StartupShortcut -Force
                }
                catch { $rollbackErrors.Add('startup shortcut') }
            }
            if ($unattendedEnabledThisRun) {
                try { Invoke-MeshClipExternal -FilePath $tailscale -ArgumentList @('set', '--unattended=false') | Out-Null }
                catch { $rollbackErrors.Add('Tailscale unattended mode') }
            }
            if ($rollbackErrors.Count -gt 0) {
                throw "Setup state could not be saved and rollback was incomplete for: $($rollbackErrors -join ', ')."
            }
            throw 'Setup state could not be saved; changes made by this run were rolled back.'
        }
    }

    Write-Host ''
    Write-Host 'Next: put both computers in the same Tailnet, then run configure-peer.ps1 on each computer from an elevated PowerShell 7 window.'
}
finally {
    Exit-MeshClipOperationLock -Lock $lock
}

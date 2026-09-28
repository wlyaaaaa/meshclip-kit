#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess = $true)]
param([Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedCommit)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MeshClip.Common.psm1') -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$actualCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $ExpectedCommit) {
    throw 'Repository HEAD differs from the reviewed deployment commit.'
}
if (-not $IsWindows -or [Environment]::OSVersion.Version.Build -lt 22000) { throw 'Windows 11 is required.' }
if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem -or (Get-Process -Id $PID).SessionId -eq 0) {
    throw 'Run in the intended signed-in Windows user session, not SYSTEM or session 0.'
}

$state = Get-MeshClipState
Assert-MeshClipNoPendingTransaction -State $state
$startup = Get-MeshClipStartupInfo
if ($startup.Exists -and -not $startup.OwnedAndUnchanged) {
    throw 'The KDE login shortcut is not project-owned and unchanged; preserve it for review.'
}
if ((Get-MeshClipWatchdogStartupInfo).Exists -or (Get-MeshClipWatchdogTaskInfo).Exists -or
    (Get-MeshClipWatchdogProcessInfo).Count -gt 0) {
    throw 'A watchdog layer still exists. Review and remove it before choosing on-demand mode.'
}

if ($WhatIfPreference) {
    & (Join-Path $PSScriptRoot 'install-windows.ps1') -SkipKdeStartup -SkipKdeWatchdog -NoLaunchKdeConnect -WhatIf -AsJson
    [pscustomobject]@{status='preview';kde_mode='on_demand';remove_owned_startup=$startup.Exists;commit=$actualCommit} | ConvertTo-Json
    return
}

& (Join-Path $PSScriptRoot 'install-windows.ps1') -SkipKdeStartup -SkipKdeWatchdog -NoLaunchKdeConnect -AsJson -Confirm:$false | Out-Null
if (-not (Get-MeshClipKdeExecutable -Kind indicator)) { throw 'KDE Connect installation did not verify; on-demand mode was not recorded.' }
$tailscale = Get-MeshClipTailscaleStatus
if ($tailscale.BackendState -ne 'Running' -or -not $tailscale.SelfOnline) {
    throw 'Tailscale is not online; on-demand mode was not recorded.'
}

$lock = Enter-MeshClipOperationLock
try {
    $state = Get-MeshClipState
    Assert-MeshClipNoPendingTransaction -State $state
    $startup = Get-MeshClipStartupInfo
    if ($startup.Exists) {
        if (-not $startup.OwnedAndUnchanged) { throw 'The KDE login shortcut changed; it was preserved.' }
        if ($PSCmdlet.ShouldProcess('Project-owned KDE login shortcut', 'Remove for on-demand mode')) {
            Remove-Item -LiteralPath (Get-MeshClipPaths).StartupShortcut -Force
        }
    }
    if ((Get-MeshClipWatchdogStartupInfo).Exists -or (Get-MeshClipWatchdogTaskInfo).Exists -or
        (Get-MeshClipWatchdogProcessInfo).Count -gt 0) { throw 'A watchdog layer appeared; on-demand mode was not recorded.' }
    $state.startupShortcutCreated = $false
    $state.watchdogShortcutCreated = $false
    $state.watchdogTaskCreated = $false
    $state.kdeMode = 'on_demand'
    Save-MeshClipState -State $state
    [pscustomobject]@{status='configured';kde_mode='on_demand';commit=$actualCommit;business_acceptance='not_tested'} | ConvertTo-Json
}
finally { Exit-MeshClipOperationLock -Lock $lock }

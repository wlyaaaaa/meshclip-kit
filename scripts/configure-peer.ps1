#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string] $Peer,
    [switch] $DisableBroadKdeFirewallRules,
    [switch] $SkipFirewall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MeshClip.Common.psm1') -Force

if (-not $IsWindows) {
    throw 'MeshClip Kit peer configuration can only run on Windows.'
}
if ($SkipFirewall -and $DisableBroadKdeFirewallRules) {
    throw '-DisableBroadKdeFirewallRules cannot be combined with -SkipFirewall.'
}
if (-not $SkipFirewall -and -not (Test-MeshClipAdministrator)) {
    throw 'Open PowerShell 7 as Administrator before configuring a peer, or use -SkipFirewall for a config-only preview.'
}

$lock = Enter-MeshClipOperationLock
try {
    $status = Get-MeshClipTailscaleStatus
    if ($status.BackendState -ne 'Running' -or -not $status.SelfOnline) {
        throw 'Tailscale must be authenticated and online before peer configuration.'
    }
    $selected = Resolve-MeshClipApprovedWindowsPeer -Status $status -Peer $Peer
    $redactedAddress = ConvertTo-MeshClipRedactedAddress -Address $selected.Address
    Write-Host "Selected exactly one online Windows Tailnet peer at $redactedAddress. Full identity is intentionally not printed."

    $firewallAudit = $null
    $doDisableBroad = $false
    if (-not $SkipFirewall) {
        $firewallAudit = Get-MeshClipKdeFirewallAudit -Address $selected.Address
        if ($firewallAudit.Status -ne 'Available') {
            throw 'The unmanaged KDE firewall audit is unavailable; refusing to configure firewall access.'
        }
        if ($firewallAudit.BroadInboundAllow -gt 0) {
            if (-not $DisableBroadKdeFirewallRules) {
                throw 'Broad unmanaged KDE Connect inbound firewall rules exist. Review the -WhatIf plan, then rerun with -DisableBroadKdeFirewallRules.'
            }
            $doDisableBroad = $PSCmdlet.ShouldProcess(
                'Windows Firewall',
                'Disable only broad unmanaged inbound KDE Connect rules and record them for optional rollback'
            )
            if (-not $doDisableBroad -and -not $WhatIfPreference) {
                throw 'Broad unmanaged KDE Connect rules remain enabled; peer configuration was stopped.'
            }
        }
    }

    $doConfig = $PSCmdlet.ShouldProcess('KDE Connect customDevices', "Add approved peer $redactedAddress")
    $doFirewall = -not $SkipFirewall -and $PSCmdlet.ShouldProcess(
        'Windows Firewall',
        "Create exact-peer KDE Connect TCP/UDP rules for $redactedAddress"
    )
    $cli = Get-MeshClipKdeExecutable -Kind cli
    $doRefresh = [bool]($cli -and $PSCmdlet.ShouldProcess('KDE Connect', 'Refresh device discovery'))

    $stateBefore = Get-MeshClipState
    $state = $stateBefore | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $configResult = $null
    $firewallResult = $null
    $disabledNames = @()
    $transactionStarted = -not $WhatIfPreference -and ($doDisableBroad -or $doConfig -or $doFirewall)

    if ($transactionStarted) {
        $state.pendingTransaction = [pscustomobject]@{
            operation = 'configure-peer'
            phase     = 'started'
            startedAt = [DateTimeOffset]::UtcNow.ToString('O')
        }
        Save-MeshClipState -State $state
    }

    try {
        if ($doDisableBroad) {
            $disabledNames = @(Disable-MeshClipBroadKdeFirewallRules -Address $selected.Address)
            $state.disabledBroadFirewallRules = @(
                $state.disabledBroadFirewallRules + $disabledNames | Select-Object -Unique
            )
            Write-Host '[PASS] Broad unmanaged KDE Connect inbound rules were disabled and recorded for optional rollback.'
        }

        if ($doConfig) {
            $configResult = Write-MeshClipKdeConfigChange -Action Add -Address $selected.Address
            if ($configResult.Changed) {
                $state.addedPeers = @($state.addedPeers + $selected.Address | Select-Object -Unique)
                Write-Host '[PASS] Added the peer to KDE Connect customDevices; only the config file was backed up.'
            }
            else {
                Write-Host '[PASS] KDE Connect customDevices already contains this peer.'
            }
        }

        if ($doFirewall) {
            $firewallResult = New-MeshClipFirewallRules -Address $selected.Address
            $state.firewallRules = @($state.firewallRules + $firewallResult.Names | Select-Object -Unique)
            Write-Host '[PASS] Exact-peer KDE Connect firewall rules are present.'
        }
        elseif ($SkipFirewall) {
            Write-Warning 'Firewall configuration was skipped. This device is not fully configured.'
        }

        if ($doRefresh) {
            try {
                Invoke-MeshClipExternal -FilePath $cli -ArgumentList @('--refresh') | Out-Null
            }
            catch {
                Write-Warning 'KDE Connect refresh could not be confirmed. Restart the indicator manually.'
            }
        }

        if ($transactionStarted) {
            $state.pendingTransaction = $null
            Save-MeshClipState -State $state
        }
    }
    catch {
        $originalError = $_
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        if ($firewallResult -and @($firewallResult.CreatedNames).Count -gt 0) {
            try { Remove-MeshClipFirewallRules -Names @($firewallResult.CreatedNames) }
            catch { $rollbackErrors.Add('new firewall rules') }
        }
        if ($configResult -and $configResult.Changed) {
            try { Restore-MeshClipKdeConfigChange -Change $configResult }
            catch { $rollbackErrors.Add('KDE Connect config') }
        }
        if (@($disabledNames).Count -gt 0) {
            try { Enable-MeshClipDisabledUnmanagedKdeFirewallRules -Names $disabledNames }
            catch { $rollbackErrors.Add('disabled unmanaged firewall rules') }
        }
        if ($transactionStarted) {
            try { Save-MeshClipState -State $stateBefore }
            catch { $rollbackErrors.Add('local transaction state') }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "Peer configuration failed and rollback was incomplete for: $($rollbackErrors -join ', '). Run doctor.ps1 before making more changes."
        }
        throw $originalError
    }

    Write-Host ''
    Write-Host 'User action required: confirm the same KDE Connect pairing request on both computers.'
    Write-Host 'After pairing, disable the peer Clipboard option "Including passwords" on both computers.'
    Write-Host 'Repeat configure-peer.ps1 on the other computer so both inbound firewalls approve the exact opposite peer.'
}
finally {
    Exit-MeshClipOperationLock -Lock $lock
}

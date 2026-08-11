#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Peer,

    [switch] $AllowOfflinePeer,
    [switch] $SkipFirewall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MeshClip.Common.psm1') -Force

if (-not $IsWindows) {
    throw 'MeshClip Kit peer configuration can only run on Windows.'
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
    $selected = Resolve-MeshClipPeer -Status $status -Peer $Peer
    if (-not $selected.Online -and -not $AllowOfflinePeer) {
        throw 'The selected peer is currently offline. Use -AllowOfflinePeer only after verifying the intended device locally.'
    }

    $redactedAddress = ConvertTo-MeshClipRedactedAddress -Address $selected.Address
    Write-Host "Selected one exact Tailnet peer at $redactedAddress. Full identity is intentionally not printed."

    $state = Get-MeshClipState
    $stateChanged = $false

    if ($PSCmdlet.ShouldProcess('KDE Connect customDevices', "Add approved peer $redactedAddress")) {
        $configResult = Write-MeshClipKdeConfigChange -Action Add -Address $selected.Address
        if ($configResult.Changed) {
            $state.addedPeers = @($state.addedPeers + $selected.Address | Select-Object -Unique)
            $stateChanged = $true
            Write-Host '[PASS] Added the peer to KDE Connect customDevices; only the config file was backed up.'
        }
        else {
            Write-Host '[PASS] KDE Connect customDevices already contains this peer.'
        }
    }

    if (-not $SkipFirewall) {
        if ($PSCmdlet.ShouldProcess('Windows Firewall', "Create exact-peer KDE Connect TCP/UDP rules for $redactedAddress")) {
            $ruleNames = New-MeshClipFirewallRules -Address $selected.Address
            $state.firewallRules = @($state.firewallRules + $ruleNames | Select-Object -Unique)
            $stateChanged = $true
            Write-Host '[PASS] Exact-peer KDE Connect firewall rules are present.'
        }
    }
    else {
        Write-Warning 'Firewall configuration was skipped. This device is not fully configured.'
    }

    $cli = Get-MeshClipKdeExecutable -Kind cli
    if ($cli -and $PSCmdlet.ShouldProcess('KDE Connect', 'Refresh device discovery')) {
        try {
            Invoke-MeshClipExternal -FilePath $cli -ArgumentList @('--refresh') | Out-Null
        }
        catch {
            Write-Warning 'KDE Connect refresh could not be confirmed. Restart the indicator manually.'
        }
    }

    if ($stateChanged -and -not $WhatIfPreference) {
        Save-MeshClipState -State $state
    }

    Write-Host ''
    Write-Host 'User action required: confirm KDE Connect pairing on both computers.'
    Write-Host 'After pairing, disable the peer Clipboard option "Including passwords" on both computers.'
    Write-Host 'Repeat configure-peer.ps1 on the other computer so both inbound firewalls approve the exact opposite peer.'
}
finally {
    Exit-MeshClipOperationLock -Lock $lock
}

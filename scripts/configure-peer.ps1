#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param([string]$Peer, [switch]$DisableBroadKdeFirewallRules, [switch]$SkipFirewall)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MeshClip.Common.psm1') -Force
if (-not $IsWindows) { throw 'Windows is required.' }
if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { throw 'Use the intended Windows user, not SYSTEM.' }
if ($SkipFirewall -and $DisableBroadKdeFirewallRules) { throw 'The firewall options conflict.' }
$lock = Enter-MeshClipOperationLock
try {
    $state = Get-MeshClipState
    Assert-MeshClipNoPendingTransaction -State $state
    $status = Get-MeshClipTailscaleStatus
    if ($status.BackendState -ne 'Running' -or -not $status.SelfOnline) { throw 'Tailscale must be online.' }
    $selected = Resolve-MeshClipApprovedWindowsPeer -Status $status -Peer $Peer
    $redacted = ConvertTo-MeshClipRedactedAddress -Address $selected.Address
    $audit = $null
    if (-not $SkipFirewall) {
        if (-not $WhatIfPreference -and -not (Test-MeshClipAdministrator)) { throw 'Firewall changes require elevation for the same Windows user.' }
        $audit = Get-MeshClipKdeFirewallAudit -Address $selected.Address
        if ($audit.Status -ne 'Available') { throw 'The effective firewall policy could not be audited.' }
        if ($audit.BroadInboundAllow -gt 0 -and -not $DisableBroadKdeFirewallRules) { throw 'Broad unmanaged KDE rules exist. Review -WhatIf, then explicitly use -DisableBroadKdeFirewallRules.' }
    }
    try {
        if ($audit -and $audit.BroadInboundAllow -gt 0) {
            if (-not $PSCmdlet.ShouldProcess('Only the identified unmanaged KDE firewall rules', 'Disable broad inbound access with recorded preimages')) {
                if (-not $WhatIfPreference) { throw 'Broad inbound access remains; configuration was not applied.' }
            }
            else {
                if (-not $state.pendingTransaction) { Start-MeshClipTransaction -State $state -Operation 'configure-peer' }
                # Keep each preimage, not merely an in-memory list returned AFTER
                # all changes. This also covers interruption inside the helper.
                $disableSteps = @(
                    foreach ($name in @($audit.BroadRuleNames)) {
                        $rule = Get-NetFirewallRule -Name $name -PolicyStore PersistentStore -ErrorAction Stop
                        $snapshot = Get-MeshClipFirewallSnapshot -Rule $rule
                        if ($snapshot.enabled -ne 'True') { throw 'A firewall rule changed after planning.' }
                        Add-MeshClipTransactionStep -State $state -Kind FirewallDisable -Data $snapshot
                    }
                )
                foreach ($step in $disableSteps) {
                    # Mutate only the previously journaled rules, never a fresh wider audit set.
                    $rule = Get-NetFirewallRule -Name $step.data.name -PolicyStore PersistentStore -ErrorAction Stop
                    $current = Get-MeshClipFirewallSnapshot -Rule $rule
                    if ($current.shape -cne $step.data.shape -or $current.enabled -ne 'True') { throw 'A firewall rule changed after its preimage was saved.' }
                    $rule | Disable-NetFirewallRule -ErrorAction Stop
                    $readback = Get-NetFirewallRule -Name $step.data.name -PolicyStore PersistentStore -ErrorAction Stop
                    if ([string]$readback.Enabled -ne 'False') { throw 'Firewall disable did not verify.' }
                    $state.disabledBroadFirewallRules = @($state.disabledBroadFirewallRules + $step.data.name | Select-Object -Unique)
                    Complete-MeshClipTransactionStep -State $state -Step $step
                }
            }
        }
        if ($PSCmdlet.ShouldProcess('KDE Connect customDevices', "Add approved peer $redacted")) {
            $plan = New-MeshClipConfigPlan -Action Add -Address $selected.Address
            if ($plan.Changed) {
                if (-not $state.pendingTransaction) { Start-MeshClipTransaction -State $state -Operation 'configure-peer' }
                $step = Add-MeshClipTransactionStep -State $state -Kind KdeConfig -Data $plan
                Set-MeshClipConfigPlan -Plan $plan | Out-Null
                $state.addedPeers = @($state.addedPeers + $selected.Address | Select-Object -Unique)
                Complete-MeshClipTransactionStep -State $state -Step $step
            }
        }
        if (-not $SkipFirewall -and $PSCmdlet.ShouldProcess('Windows Firewall', "Create exact-peer rules for $redacted")) {
            $names = @(Get-MeshClipFirewallRuleNames -Address $selected.Address)
            $allRules = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop)
            $missing = @($names | Where-Object { $_ -notin @($allRules.DisplayName) })
            $step = $null
            if ($missing.Count) {
                if (-not $state.pendingTransaction) { Start-MeshClipTransaction -State $state -Operation 'configure-peer' }
                $step = Add-MeshClipTransactionStep -State $state -Kind FirewallCreate -Data @{ names = $missing; ruleNames = $missing; address = $selected.Address }
            }
            $result = New-MeshClipFirewallRules -Address $selected.Address
            $daemon = Get-MeshClipKdeExecutable -Kind daemon
            $adapter = Get-MeshClipTailscaleAdapterAlias
            $effective = @(Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop)
            for ($i = 0; $i -lt $names.Count; $i++) {
                $rules = @($effective | Where-Object DisplayName -eq $names[$i])
                $protocol = @('TCP','UDP')[$i]
                if ($rules.Count -ne 1 -or -not (Test-MeshClipFirewallRuleCompliant -Rule $rules[0] -Protocol $protocol -Address $selected.Address -Program $daemon -InterfaceAlias $adapter)) { throw 'Exact-peer rules did not verify in ActiveStore.' }
            }
            if ($step) {
                $state.firewallRules = @($state.firewallRules + $result.CreatedNames | Select-Object -Unique)
                Complete-MeshClipTransactionStep -State $state -Step $step
            }
        }
        Complete-MeshClipTransaction -State $state
    }
    catch {
        $cause = $_
        if ($state.pendingTransaction) {
            $recovery = Repair-MeshClipTransaction -State $state
            if ($recovery.status -ne 'recovered') { throw 'Peer configuration failed; incomplete recovery is still recorded. Run recover.ps1.' }
        }
        throw $cause
    }
    if ($SkipFirewall) { Write-Warning 'Config-only operation; firewall acceptance is not complete.' }
    $cli = Get-MeshClipKdeExecutable -Kind cli
    if ($cli -and $PSCmdlet.ShouldProcess('KDE Connect', 'Refresh discovery after committed configuration')) {
        try { Invoke-MeshClipExternal -FilePath $cli -ArgumentList @('--refresh') | Out-Null }
        catch { Write-Warning 'Configuration committed; discovery refresh could not be verified.' }
    }
    Write-Host 'Confirm the same pairing request on both devices. Disable Including passwords on both peers. Run acceptance.ps1; configuration is not end-to-end acceptance.'
}
finally { Exit-MeshClipOperationLock -Lock $lock }

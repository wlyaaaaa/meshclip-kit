#Requires -Version 7.0
# Dot-sourced by MeshClip.Common. The journal contains only integration preimages,
# stays in the current user's private state directory, and is never diagnostic output.
function Write-MeshClipAtomicJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $temp = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 40) + "`n")
        $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
        [void](Get-Content -LiteralPath $temp -Raw | ConvertFrom-Json -Depth 40)
        [IO.File]::Move($temp, $Path, $true)
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Assert-MeshClipNoPendingTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    if ($State.pendingTransaction) {
        throw 'An unfinished MeshClip operation exists. Use recover.ps1 to inspect and recover it before another write.'
    }
}

function Start-MeshClipTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Operation)
    Assert-MeshClipNoPendingTransaction -State $State
    $before = $State | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $State.pendingTransaction = [pscustomobject]@{
        schemaVersion = 1; id = [Guid]::NewGuid().ToString('N'); operation = $Operation
        phase = 'applying'; startedAt = [DateTimeOffset]::UtcNow.ToString('O')
        before = $before; steps = @(); remaining = @()
    }
    Save-MeshClipState -State $State
}

function Add-MeshClipTransactionStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][ValidateSet('TailscaleMode','ShortcutCreate','WatchdogTaskCreate','KdeConfig','FirewallCreate','FirewallDisable')][string]$Kind,
        [Parameter(Mandatory)]$Data)
    if (-not $State.pendingTransaction -or $State.pendingTransaction.phase -ne 'applying') { throw 'No writable integration transaction.' }
    $step = [pscustomobject]@{ kind = $Kind; phase = 'prepared'; data = $Data }
    $State.pendingTransaction.steps = @($State.pendingTransaction.steps) + $step
    # Persist intent BEFORE the side effect. A crash after the effect but before
    # the next save is recoverable by comparing the exact before/after states.
    Save-MeshClipState -State $State
    return $step
}

function Complete-MeshClipTransactionStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Step)
    $Step.phase = 'applied'
    Save-MeshClipState -State $State
}

function Complete-MeshClipTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    $journal = $State.pendingTransaction
    if (-not $journal) { return }
    if (@($journal.steps | Where-Object phase -ne 'applied').Count) { throw 'An integration step has not completed.' }
    $State.pendingTransaction = $null
    try { Save-MeshClipState -State $State }
    catch { $State.pendingTransaction = $journal; throw }
}

function New-MeshClipConfigPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Add','Remove')][string]$Action,
        [Parameter(Mandatory)][string]$Address)
    $path = (Get-MeshClipPaths).KdeConfigPath
    $document = Read-MeshClipTextDocument -Path $path
    $lines = @($document.Lines)
    $repaired = $false
    if ($Action -eq 'Add') {
        $legacy = Repair-MeshClipLegacyDuplicateGeneralLines -Lines $lines -Address $Address
        $lines = @($legacy.Lines); $repaired = $legacy.Changed
        $result = Add-MeshClipCustomDeviceToLines -Lines $lines -Address $Address
    } else { $result = Remove-MeshClipCustomDeviceFromLines -Lines $lines -Address $Address }
    $changed = $result.Changed -or $repaired
    $content = $result.Lines -join $document.NewLine
    if ($document.EndsNewLine -or -not $document.Exists) { $content += $document.NewLine }
    $encoding = [Text.UTF8Encoding]::new($document.HasBom)
    [byte[]]$bytes = @($encoding.GetPreamble()) + @($encoding.GetBytes($content))
    [byte[]]$beforeBytes = @(); if ($document.Exists) { $beforeBytes = [IO.File]::ReadAllBytes($path) }
    $originalHash = if ($document.Exists) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$beforeBytes)) } else { $null }
    if ($originalHash -ne $document.Hash) { throw 'KDE config changed while planning. Nothing was changed.' }
    [pscustomobject]@{
        Changed = $changed; OriginalExists = $document.Exists; OriginalHash = $originalHash
        ResultHash = if ($changed) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) } else { $originalHash }
        OriginalBytesBase64 = [Convert]::ToBase64String([byte[]]$beforeBytes)
        ResultBytesBase64 = [Convert]::ToBase64String($bytes)
        Devices = @($result.Devices); BackupPath = $null
    }
}

function Set-MeshClipConfigPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    if (-not $Plan.Changed) { return $Plan }
    $paths = Get-MeshClipPaths
    $current = Get-MeshClipFileHashSafe -Path $paths.KdeConfigPath
    if ($current -ne $Plan.OriginalHash) { throw 'KDE config changed after planning. Nothing was changed.' }
    $bytes = [Convert]::FromBase64String($Plan.ResultBytesBase64)
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -ne $Plan.ResultHash) { throw 'Invalid config plan.' }
    if ($Plan.OriginalExists) {
        [IO.Directory]::CreateDirectory($paths.BackupsRoot) | Out-Null
        $backup = Join-Path $paths.BackupsRoot ("kdeconnect-config-{0}.bak" -f $Plan.OriginalHash)
        if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::WriteAllBytes($backup, [Convert]::FromBase64String($Plan.OriginalBytesBase64)) }
        if ((Get-MeshClipFileHashSafe -Path $backup) -ne $Plan.OriginalHash) { throw 'Config preimage could not be verified.' }
        $Plan.BackupPath = $backup
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $paths.KdeConfigPath)) | Out-Null
    $temp = "$($paths.KdeConfigPath).meshclip.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temp, $bytes)
        [void](Get-MeshClipCustomDevicesFromLines -Lines (Read-MeshClipTextDocument -Path $temp).Lines)
        if ((Get-MeshClipFileHashSafe -Path $paths.KdeConfigPath) -ne $Plan.OriginalHash) { throw 'KDE config changed before replacement.' }
        [IO.File]::Move($temp, $paths.KdeConfigPath, $true)
        if ((Get-MeshClipFileHashSafe -Path $paths.KdeConfigPath) -ne $Plan.ResultHash) { throw 'KDE config write could not be verified.' }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    return $Plan
}

function Undo-MeshClipConfigPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    if (-not $Plan.Changed) { return }
    $path = (Get-MeshClipPaths).KdeConfigPath
    $current = Get-MeshClipFileHashSafe -Path $path
    if ($current -eq $Plan.OriginalHash) { return }
    if ($current -ne $Plan.ResultHash) { throw 'KDE config changed after this operation; preserved for manual reconciliation.' }
    if (-not $Plan.OriginalExists) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    else {
        [byte[]]$bytes = [Convert]::FromBase64String($Plan.OriginalBytesBase64)
        if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -ne $Plan.OriginalHash) { throw 'Invalid config preimage.' }
        $temp = "$path.meshclip.restore.$([Guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::WriteAllBytes($temp, $bytes)
            if ((Get-MeshClipFileHashSafe -Path $path) -ne $Plan.ResultHash) { throw 'KDE config changed before recovery.' }
            [IO.File]::Move($temp, $path, $true)
        } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    }
    if ((Get-MeshClipFileHashSafe -Path $path) -ne $Plan.OriginalHash) { throw 'KDE config recovery did not verify.' }
}

function Get-MeshClipFirewallSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rule)
    $port = @($Rule | Get-NetFirewallPortFilter -ErrorAction Stop)
    $address = @($Rule | Get-NetFirewallAddressFilter -ErrorAction Stop)
    $application = @($Rule | Get-NetFirewallApplicationFilter -ErrorAction Stop)
    $interface = @($Rule | Get-NetFirewallInterfaceFilter -ErrorAction Stop)
    if ($port.Count -ne 1 -or $address.Count -ne 1 -or $application.Count -ne 1 -or $interface.Count -ne 1) { throw 'Ambiguous firewall filters.' }
    # Enabled is deliberately separate so recovery accepts only the expected toggle.
    $shape = [ordered]@{ name = [string]$Rule.Name; displayName = [string]$Rule.DisplayName
        group = [string]$Rule.Group; direction = [string]$Rule.Direction; action = [string]$Rule.Action
        profile = [string]$Rule.Profile; edge = [string]$Rule.EdgeTraversalPolicy
        protocol = [string]$port[0].Protocol; localPort = @($port[0].LocalPort); remotePort = @($port[0].RemotePort)
        localAddress = @($address[0].LocalAddress); remoteAddress = @($address[0].RemoteAddress)
        program = [string]$application[0].Program; interfaceAlias = @($interface[0].InterfaceAlias) }
    [pscustomobject]@{ name = [string]$Rule.Name; enabled = [string]$Rule.Enabled; shape = ($shape | ConvertTo-Json -Depth 6 -Compress) }
}

function Undo-MeshClipTransactionStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step)
    $data = $Step.data
    switch ($Step.kind) {
        'TailscaleMode' {
            $prefs = Get-MeshClipTailscalePreferences
            if (-not $prefs) { throw 'Tailscale preference is unknown.' }
            if ([bool]$prefs.ForceDaemon -ne [bool]$data.before) {
                Invoke-MeshClipExternal -FilePath (Get-MeshClipTrustedCommand -Name tailscale) -ArgumentList @('set', '--unattended=false') | Out-Null
            }
            $readback = Get-MeshClipTailscalePreferences
            if (-not $readback -or [bool]$readback.ForceDaemon -ne [bool]$data.before) { throw 'Tailscale recovery did not verify.' }
        }
        'ShortcutCreate' {
            $paths = Get-MeshClipPaths
            $info = if ($data.type -eq 'startup') { Get-MeshClipStartupInfo } else { Get-MeshClipWatchdogStartupInfo }
            $path = if ($data.type -eq 'startup') { $paths.StartupShortcut } else { $paths.WatchdogShortcut }
            if ($info.Exists) {
                if (-not $info.OwnedAndUnchanged) { throw 'Shortcut changed; preserved.' }
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $path) { throw 'Shortcut recovery did not verify.' }
        }
        'WatchdogTaskCreate' {
            $info = Get-MeshClipWatchdogTaskInfo
            if ($info.Exists) {
                if (-not $info.OwnedAndUnchanged) { throw 'Supervisor task changed; preserved.' }
                Remove-MeshClipWatchdogTask | Out-Null
            }
            if ((Get-MeshClipWatchdogTaskInfo).Exists) { throw 'Task recovery did not verify.' }
        }
        'KdeConfig' { Undo-MeshClipConfigPlan -Plan $data }
        'FirewallCreate' {
            $daemon = Get-MeshClipKdeExecutable -Kind daemon
            $adapter = Get-MeshClipTailscaleAdapterAlias
            foreach ($name in @($data.names)) {
                $identityProperty = if ($data.PSObject.Properties['ruleNames']) { 'Name' } else { 'DisplayName' }
                $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object -Property $identityProperty -EQ $name)
                if (-not $rules.Count) { continue }
                $protocol = if ($name.EndsWith('-TCP')) { 'TCP' } else { 'UDP' }
                if ($rules.Count -ne 1 -or -not (Test-MeshClipFirewallRuleCompliant -Rule $rules[0] -Protocol $protocol -Address $data.address -Program $daemon -InterfaceAlias $adapter)) { throw 'A new firewall rule changed; preserved.' }
                Remove-NetFirewallRule -Name ([string]$rules[0].Name) -PolicyStore PersistentStore -ErrorAction Stop
                if (@(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object -Property $identityProperty -EQ $name).Count) { throw 'Firewall removal did not verify.' }
            }
        }
        'FirewallDisable' {
            $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object Name -eq $data.name)
            if ($rules.Count -ne 1) { throw 'Recorded firewall rule is missing or ambiguous.' }
            $now = Get-MeshClipFirewallSnapshot -Rule $rules[0]
            if ($now.shape -cne $data.shape) { throw 'Recorded firewall rule changed; preserved.' }
            if ($now.enabled -eq 'False') { $rules[0] | Enable-NetFirewallRule -ErrorAction Stop }
            $readback = Get-NetFirewallRule -Name $data.name -PolicyStore PersistentStore -ErrorAction Stop
            if ([string]$readback.Enabled -ne 'True') { throw 'Firewall restore did not verify.' }
        }
        default { throw 'Unsupported recovery step; preserved.' }
    }
}

function Repair-MeshClipTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    $journal = $State.pendingTransaction
    if (-not $journal) { return [pscustomobject]@{ status = 'nothing_to_recover'; remaining = @() } }
    if (-not $journal.PSObject.Properties['schemaVersion'] -or $journal.schemaVersion -ne 1 -or
        -not $journal.PSObject.Properties['before'] -or -not $journal.PSObject.Properties['steps']) {
        throw 'Legacy incomplete transaction has no safe preimage. It was not cleared; reconcile the machine explicitly.'
    }
    $journal.phase = 'recovering'
    Save-MeshClipState -State $State
    $errors = [Collections.Generic.List[string]]::new()
    $steps = @($journal.steps)
    for ($i = $steps.Count - 1; $i -ge 0; $i--) {
        if ($steps[$i].phase -eq 'restored') { continue }
        try {
            Undo-MeshClipTransactionStep -Step $steps[$i]
            $steps[$i].phase = 'restored'
            Save-MeshClipState -State $State
        } catch { $errors.Add("step[$i]:$($steps[$i].kind)") }
    }
    if ($errors.Count) {
        $journal.phase = 'recovery_required'; $journal.remaining = @($errors)
        Save-MeshClipState -State $State
        return [pscustomobject]@{ status = 'recovery_required'; remaining = @($errors) }
    }
    # Clear only AFTER every inverse operation has passed its actual readback.
    Save-MeshClipState -State $journal.before
    return [pscustomobject]@{ status = 'recovered'; remaining = @() }
}

function Get-MeshClipRecoverySummary {
    [CmdletBinding()]
    param()
    $state = Get-MeshClipState
    $journal = $state.pendingTransaction
    if (-not $journal) { return [pscustomobject]@{ pending = $false; operation = $null; phase = 'clean'; steps = @() } }
    [pscustomobject]@{ pending = $true; operation = [string]$journal.operation; phase = [string]$journal.phase
        recoverable = [bool]($journal.PSObject.Properties['before'] -and $journal.PSObject.Properties['steps'])
        steps = if ($journal.PSObject.Properties['steps']) { @($journal.steps | Select-Object kind,phase) } else { @() } }
}

function Get-MeshClipWatchdogControl {
    [CmdletBinding()]
    param()
    $path = Join-Path (Get-MeshClipPaths).StateRoot 'watchdog-control.json'
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ mode = 'enabled'; paused = $false; resumeAt = $null } }
    try {
        $control = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($control.schemaVersion -ne 1 -or $control.mode -notin @('enabled','paused')) { throw 'Invalid watchdog control.' }
        $paused = $control.mode -eq 'paused'
        if ($paused -and $control.resumeAt) { $paused = [DateTimeOffset]::UtcNow -lt (ConvertTo-MeshClipDateTimeOffset $control.resumeAt) }
        [pscustomobject]@{ mode = if ($paused) { 'paused' } else { 'enabled' }; paused = $paused; resumeAt = $control.resumeAt }
    } catch { throw 'Watchdog control is unreadable. Automatic relaunch is suspended until control is repaired.' }
}

function Set-MeshClipWatchdogControl {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][ValidateSet('Pause','Resume')][string]$Mode,
        [ValidateRange(0,10080)][int]$Minutes = 0)
    $path = Join-Path (Get-MeshClipPaths).StateRoot 'watchdog-control.json'
    if ($PSCmdlet.ShouldProcess('MeshClip watchdog', $Mode)) {
        $value = [ordered]@{ schemaVersion = 1; mode = if ($Mode -eq 'Pause') { 'paused' } else { 'enabled' }
            resumeAt = if ($Mode -eq 'Pause' -and $Minutes -gt 0) { [DateTimeOffset]::UtcNow.AddMinutes($Minutes).ToString('O') } else { $null } }
        Write-MeshClipAtomicJson -Path $path -Value $value
    }
    Get-MeshClipWatchdogControl
}

function Get-MeshClipWatchdogRuntimeCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ProcessInfo,[Parameter(Mandatory)]$Heartbeat,[AllowNull()]$Control,[switch]$OnDemand)
    if($OnDemand){
        if($ProcessInfo.Count -gt 0){return [pscustomobject]@{Status='FAIL';Detail='On-demand mode has an unexpected watchdog process.'}}
        return [pscustomobject]@{Status='PASS';Detail='No watchdog is expected in on-demand mode; an old heartbeat is ignored.'}
    }
    if($null -eq $Control){return [pscustomobject]@{Status='UNKNOWN';Detail='Watchdog intent could not be read; health is not inferred.'}}
    if(-not($ProcessInfo.Running -and $Heartbeat.Available -and $Heartbeat.Fresh)){
        return [pscustomobject]@{Status='FAIL';Detail='Watchdog process or heartbeat is missing, ambiguous or stale.'}
    }
    if($Control.paused){
        $detail=if($Heartbeat.Status -eq 'Paused'){'Automatic relaunch is intentionally paused; the watchdog is observing that intent.'}else{'Pause is requested; the next watchdog check must observe it.'}
        if($Heartbeat.Status -notin @('Paused','Starting','Healthy','Restarted')){return [pscustomobject]@{Status='FAIL';Detail='The watchdog reports a runtime error despite the pause request.'}}
        return [pscustomobject]@{Status='WARN';Detail=$detail}
    }
    if($Heartbeat.Status -eq 'Paused'){return [pscustomobject]@{Status='WARN';Detail='Resume is requested; the next watchdog check must observe it.'}}
    if($Heartbeat.Status -in @('Starting','Healthy','Restarted')){return [pscustomobject]@{Status='PASS';Detail='Exactly one current-session watchdog has a fresh healthy heartbeat.'}}
    [pscustomobject]@{Status='FAIL';Detail='The watchdog reports a nonhealthy runtime status.'}
}

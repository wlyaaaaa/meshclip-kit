#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectName = 'MeshClip Kit'
$script:FirewallGroup = 'MeshClip Kit'
$script:FirewallPortRange = '1714-1764'
$script:StateSchemaVersion = 1

function Get-MeshClipPaths {
    [CmdletBinding()]
    param()

    $stateRoot = Join-Path $env:LOCALAPPDATA 'MeshClipKit'
    [pscustomobject]@{
        StateRoot          = $stateRoot
        StatePath          = Join-Path $stateRoot 'user-state.json'
        BackupsRoot        = Join-Path $stateRoot 'backups'
        KdeRoot            = Join-Path $env:LOCALAPPDATA 'kdeconnect'
        KdeConfigPath      = Join-Path $env:LOCALAPPDATA 'kdeconnect\config'
        StartupShortcut    = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\KDE Connect.lnk'
    }
}

function Test-MeshClipAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Enter-MeshClipOperationLock {
    [CmdletBinding()]
    param()

    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $bytes = [Text.Encoding]::UTF8.GetBytes($sid)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).Substring(0, 12)
    $mutex = [Threading.Mutex]::new($false, "Local\MeshClipKit-$hash")
    if (-not $mutex.WaitOne(0)) {
        $mutex.Dispose()
        throw 'Another MeshClip Kit install, configure, or uninstall operation is running.'
    }
    return $mutex
}

function Exit-MeshClipOperationLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Threading.Mutex] $Lock
    )

    try {
        $Lock.ReleaseMutex()
    }
    finally {
        $Lock.Dispose()
    }
}

function Get-MeshClipTrustedCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('winget', 'tailscale')]
        [string] $Name
    )

    $knownPaths = switch ($Name) {
        'winget' {
            @(
                (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe')
            )
        }
        'tailscale' {
            @(
                (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe')
            )
        }
    }

    foreach ($path in $knownPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return $null
}

function Invoke-MeshClipExternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter()]
        [string[]] $ArgumentList = @(),

        [Parameter()]
        [int[]] $AllowedExitCodes = @(0)
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Trusted executable was not found: $FilePath"
    }

    $captured = @(& $FilePath @ArgumentList 2>&1)
    $exitCode = $LASTEXITCODE
    $output = @($captured | ForEach-Object { $_.ToString() })

    if ($exitCode -notin $AllowedExitCodes) {
        throw "External command failed with exit code $exitCode. Review the command locally; raw output was suppressed."
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Get-MeshClipKdeInstallRoot {
    [CmdletBinding()]
    param()

    $candidates = [Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\KDE Connect'))
    $candidates.Add((Join-Path $env:ProgramFiles 'KDE Connect'))
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'KDE Connect'))
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'bin\kdeconnectd.exe') -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Get-MeshClipKdeExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('app', 'cli', 'daemon', 'indicator')]
        [string] $Kind
    )

    $root = Get-MeshClipKdeInstallRoot
    if (-not $root) {
        return $null
    }

    $fileName = switch ($Kind) {
        'app'       { 'kdeconnect-app.exe' }
        'cli'       { 'kdeconnect-cli.exe' }
        'daemon'    { 'kdeconnectd.exe' }
        'indicator' { 'kdeconnect-indicator.exe' }
    }
    $path = Join-Path $root "bin\$fileName"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return (Resolve-Path -LiteralPath $path).Path
    }
    return $null
}

function Get-MeshClipTailscaleStatus {
    [CmdletBinding()]
    param()

    $tailscale = Get-MeshClipTrustedCommand -Name tailscale
    if (-not $tailscale) {
        throw 'Tailscale is not installed.'
    }

    $result = Invoke-MeshClipExternal -FilePath $tailscale -ArgumentList @('status', '--json')
    try {
        $data = ($result.Output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
    }
    catch {
        throw 'Tailscale returned status data that could not be parsed.'
    }

    $peers = @()
    if ($data.Peer) {
        foreach ($property in $data.Peer.PSObject.Properties) {
            $peer = $property.Value
            $peers += [pscustomobject]@{
                StableId     = $property.Name
                HostName     = [string]$peer.HostName
                DnsName      = [string]$peer.DNSName
                OS           = [string]$peer.OS
                Online       = [bool]$peer.Online
                Active       = [bool]$peer.Active
                TailscaleIPs = @($peer.TailscaleIPs | ForEach-Object { [string]$_ })
            }
        }
    }

    [pscustomobject]@{
        BackendState = [string]$data.BackendState
        SelfOnline   = [bool]$data.Self.Online
        Peers        = $peers
    }
}

function Get-MeshClipTailscalePreferences {
    [CmdletBinding()]
    param()

    $tailscale = Get-MeshClipTrustedCommand -Name tailscale
    if (-not $tailscale) {
        return $null
    }

    $result = Invoke-MeshClipExternal -FilePath $tailscale -ArgumentList @('debug', 'prefs')
    try {
        $prefs = ($result.Output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
        [pscustomobject]@{
            WantRunning = [bool]$prefs.WantRunning
            LoggedOut   = [bool]$prefs.LoggedOut
            ForceDaemon = [bool]$prefs.ForceDaemon
        }
    }
    catch {
        return $null
    }
}

function Resolve-MeshClipPeer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Status,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Peer
    )

    $needle = $Peer.Trim().TrimEnd('.').ToLowerInvariant()
    if ($needle -match '[\r\n,;]') {
        throw 'Peer names must not contain newlines, commas, or semicolons.'
    }

    $matchedPeers = @($Status.Peers | Where-Object {
        $names = @(
            ([string]$_.HostName).Trim().TrimEnd('.').ToLowerInvariant(),
            ([string]$_.DnsName).Trim().TrimEnd('.').ToLowerInvariant()
        )
        if ($_.DnsName) {
            $names += ([string]$_.DnsName).Split('.')[0].ToLowerInvariant()
        }
        $addresses = @($_.TailscaleIPs | ForEach-Object { $_.ToLowerInvariant() })
        $needle -in $names -or $needle -in $addresses
    })

    if ($matchedPeers.Count -eq 0) {
        throw 'No exact peer match was found in the current Tailnet.'
    }
    if ($matchedPeers.Count -gt 1) {
        throw 'The peer name is ambiguous. Use its exact full Tailscale DNS name.'
    }

    $ipv4 = @($matchedPeers[0].TailscaleIPs | Where-Object {
        $parsed = [Net.IPAddress]::None
        [Net.IPAddress]::TryParse($_, [ref]$parsed) -and $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
    })
    if ($ipv4.Count -ne 1) {
        throw 'The selected peer does not have exactly one usable Tailscale IPv4 address.'
    }

    [pscustomobject]@{
        StableId = $matchedPeers[0].StableId
        HostName = $matchedPeers[0].HostName
        DnsName  = $matchedPeers[0].DnsName
        OS       = $matchedPeers[0].OS
        Online   = $matchedPeers[0].Online
        Address  = $ipv4[0]
    }
}

function Resolve-MeshClipApprovedWindowsPeer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Status,

        [string] $Peer
    )

    $onlineWindowsPeers = @($Status.Peers | Where-Object {
        [bool]$_.Online -and ([string]$_.OS).Equals('windows', [StringComparison]::OrdinalIgnoreCase)
    })

    if (-not $Peer) {
        if ($onlineWindowsPeers.Count -ne 1) {
            throw 'Automatic selection requires exactly one online Windows peer in the current Tailnet.'
        }
        $candidate = $onlineWindowsPeers[0]
        $peer = if ($candidate.HostName) { [string]$candidate.HostName } else { [string]$candidate.DnsName }
    }

    $selected = Resolve-MeshClipPeer -Status $Status -Peer $Peer
    if (-not $selected.Online -or -not ([string]$selected.OS).Equals('windows', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The selected device is not an online Windows peer.'
    }
    return $selected
}

function ConvertTo-MeshClipRedactedAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Address
    )

    $parsed = [Net.IPAddress]::None
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        return '<redacted>'
    }
    if ($parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        return "$($Address.Split('.')[0]).x.x.x"
    }
    return "$($Address.Split(':')[0]):<redacted>"
}

function Get-MeshClipFileHashSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Read-MeshClipTextDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Exists      = $false
            Lines       = @()
            NewLine     = "`r`n"
            EndsNewLine = $true
            HasBom      = $false
            Hash        = $null
        }
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing to edit a KDE Connect config file through a reparse point.'
    }

    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    $newLine = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $endsNewLine = $text.EndsWith("`n")
    $normalized = $text -replace "`r`n", "`n"
    if ($endsNewLine) {
        $normalized = $normalized.Substring(0, $normalized.Length - 1)
    }
    $lines = if ($normalized.Length -eq 0) { @() } else { @($normalized -split "`n") }

    [pscustomobject]@{
        Exists      = $true
        Lines       = $lines
        NewLine     = $newLine
        EndsNewLine = $endsNewLine
        HasBom      = $hasBom
        Hash        = Get-MeshClipFileHashSafe -Path $item.FullName
    }
}

function Get-MeshClipCustomDevicesFromLines {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $Lines = @()
    )

    $generalIndices = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -ieq '[General]') {
            $generalIndices += $i
        }
    }
    if ($generalIndices.Count -gt 1) {
        throw 'The KDE Connect config contains duplicate [General] sections.'
    }
    if ($generalIndices.Count -eq 0) {
        return [pscustomobject]@{ GeneralIndex = -1; KeyIndex = -1; Devices = @() }
    }

    $generalIndex = $generalIndices[0]
    $sectionEnd = $Lines.Count
    for ($i = $generalIndex + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -match '^\[.+\]$') {
            $sectionEnd = $i
            break
        }
    }

    $keyIndices = @()
    for ($i = $generalIndex + 1; $i -lt $sectionEnd; $i++) {
        if ($Lines[$i] -match '^\s*customDevices\s*=') {
            $keyIndices += $i
        }
    }
    if ($keyIndices.Count -gt 1) {
        throw 'The KDE Connect config contains duplicate customDevices keys.'
    }
    if ($keyIndices.Count -eq 0) {
        return [pscustomobject]@{ GeneralIndex = $generalIndex; KeyIndex = -1; Devices = @() }
    }

    $value = ($Lines[$keyIndices[0]] -split '=', 2)[1]
    $devices = @($value.Split(',', [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    [pscustomobject]@{ GeneralIndex = $generalIndex; KeyIndex = $keyIndices[0]; Devices = $devices }
}

function Add-MeshClipCustomDeviceToLines {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $Lines = @(),

        [Parameter(Mandatory)]
        [string] $Address
    )

    $parsed = [Net.IPAddress]::None
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        throw 'The custom device address is not a valid IP address.'
    }

    $list = [Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) { $list.Add($line) }
    $current = Get-MeshClipCustomDevicesFromLines -Lines $list.ToArray()
    if ($Address -in $current.Devices) {
        return [pscustomobject]@{ Changed = $false; Lines = $list.ToArray(); Devices = $current.Devices }
    }

    $devices = @($current.Devices) + $Address
    if ($current.GeneralIndex -lt 0) {
        if ($list.Count -gt 0 -and $list[$list.Count - 1] -ne '') { $list.Add('') }
        $list.Add('[General]')
        $list.Add("customDevices=$($devices -join ',')")
    }
    elseif ($current.KeyIndex -lt 0) {
        $list.Insert($current.GeneralIndex + 1, "customDevices=$($devices -join ',')")
    }
    else {
        $list[$current.KeyIndex] = "customDevices=$($devices -join ',')"
    }

    [pscustomobject]@{ Changed = $true; Lines = $list.ToArray(); Devices = $devices }
}

function Remove-MeshClipCustomDeviceFromLines {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $Lines = @(),

        [Parameter(Mandatory)]
        [string] $Address
    )

    $list = [Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) { $list.Add($line) }
    $current = Get-MeshClipCustomDevicesFromLines -Lines $list.ToArray()
    if ($Address -notin $current.Devices) {
        return [pscustomobject]@{ Changed = $false; Lines = $list.ToArray(); Devices = $current.Devices }
    }

    $devices = @($current.Devices | Where-Object { $_ -ne $Address })
    if ($devices.Count -eq 0) {
        $list.RemoveAt($current.KeyIndex)
    }
    else {
        $list[$current.KeyIndex] = "customDevices=$($devices -join ',')"
    }
    [pscustomobject]@{ Changed = $true; Lines = $list.ToArray(); Devices = $devices }
}

function Repair-MeshClipLegacyDuplicateGeneralLines {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $Lines = @(),

        [Parameter(Mandatory)]
        [string] $Address
    )

    $generalIndices = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -ieq '[General]') {
            $generalIndices += $i
        }
    }
    if ($generalIndices.Count -ne 2) {
        return [pscustomobject]@{ Changed = $false; Lines = $Lines; Devices = @() }
    }

    $legacyCandidates = @()
    foreach ($generalIndex in $generalIndices) {
        $sectionEnd = $Lines.Count
        for ($i = $generalIndex + 1; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i].Trim() -match '^\[.+\]$') {
                $sectionEnd = $i
                break
            }
        }

        $nonBlankIndices = @()
        for ($i = $generalIndex + 1; $i -lt $sectionEnd; $i++) {
            $trimmed = $Lines[$i].Trim()
            if ($trimmed) {
                $nonBlankIndices += $i
            }
        }
        if ($nonBlankIndices.Count -ne 1 -or $Lines[$nonBlankIndices[0]] -notmatch '^\s*customDevices\s*=') {
            continue
        }

        $value = ($Lines[$nonBlankIndices[0]] -split '=', 2)[1]
        $devices = @($value.Split(',', [StringSplitOptions]::RemoveEmptyEntries) |
            ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($Address -notin $devices) {
            continue
        }
        $allAddressesValid = $true
        foreach ($device in $devices) {
            $parsed = [Net.IPAddress]::None
            if (-not [Net.IPAddress]::TryParse($device, [ref]$parsed)) {
                $allAddressesValid = $false
                break
            }
        }
        if ($allAddressesValid) {
            $legacyCandidates += [pscustomobject]@{
                Start   = $generalIndex
                End     = $sectionEnd
                Devices = $devices
            }
        }
    }
    if ($legacyCandidates.Count -ne 1) {
        return [pscustomobject]@{ Changed = $false; Lines = $Lines; Devices = @() }
    }

    $legacy = $legacyCandidates[0]
    $remaining = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($i -lt $legacy.Start -or $i -ge $legacy.End) {
            $remaining.Add($Lines[$i])
        }
    }
    $remainingGeneral = @()
    for ($i = 0; $i -lt $remaining.Count; $i++) {
        if ($remaining[$i].Trim() -ieq '[General]') {
            $remainingGeneral += $i
        }
    }
    if ($remainingGeneral.Count -ne 1) {
        return [pscustomobject]@{ Changed = $false; Lines = $Lines; Devices = @() }
    }

    $remaining.Insert($remainingGeneral[0] + 1, "customDevices=$($legacy.Devices -join ',')")
    [pscustomobject]@{
        Changed = $true
        Lines   = $remaining.ToArray()
        Devices = $legacy.Devices
    }
}

function Write-MeshClipKdeConfigChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Add', 'Remove')]
        [string] $Action,

        [Parameter(Mandatory)]
        [string] $Address
    )

    $paths = Get-MeshClipPaths
    $document = Read-MeshClipTextDocument -Path $paths.KdeConfigPath
    $sourceLines = @($document.Lines)
    $legacyRepair = $null
    if ($Action -eq 'Add') {
        $legacyRepair = Repair-MeshClipLegacyDuplicateGeneralLines -Lines $sourceLines -Address $Address
        if ($legacyRepair.Changed) {
            $sourceLines = @($legacyRepair.Lines)
        }
    }
    $result = if ($Action -eq 'Add') {
        Add-MeshClipCustomDeviceToLines -Lines $sourceLines -Address $Address
    }
    else {
        Remove-MeshClipCustomDeviceFromLines -Lines $sourceLines -Address $Address
    }
    if ($legacyRepair -and $legacyRepair.Changed -and -not $result.Changed) {
        $result = [pscustomobject]@{
            Changed = $true
            Lines   = $result.Lines
            Devices = $result.Devices
        }
    }
    if (-not $result.Changed) {
        return [pscustomobject]@{
            Changed        = $false
            BackupPath     = $null
            Devices        = $result.Devices
            OriginalExists = $document.Exists
            OriginalHash   = $document.Hash
            ResultHash     = $document.Hash
        }
    }

    $configDirectory = Split-Path -Parent $paths.KdeConfigPath
    [IO.Directory]::CreateDirectory($configDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($paths.BackupsRoot) | Out-Null

    if ($document.Exists) {
        $currentHash = Get-MeshClipFileHashSafe -Path $paths.KdeConfigPath
        if ($currentHash -ne $document.Hash) {
            throw 'KDE Connect config changed while it was being prepared. No write was made.'
        }
    }
    elseif (Test-Path -LiteralPath $paths.KdeConfigPath) {
        throw 'KDE Connect config appeared while it was being prepared. No write was made.'
    }

    $backupPath = $null
    if ($document.Exists) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
        $backupPath = Join-Path $paths.BackupsRoot "kdeconnect-config-$stamp.bak"
        [IO.File]::Copy($paths.KdeConfigPath, $backupPath, $false)
    }

    $content = $result.Lines -join $document.NewLine
    if ($document.EndsNewLine -or -not $document.Exists) {
        $content += $document.NewLine
    }
    $tempPath = Join-Path $configDirectory "config.meshclip.$PID.tmp"
    $encoding = [Text.UTF8Encoding]::new($document.HasBom)
    try {
        [IO.File]::WriteAllText($tempPath, $content, $encoding)
        [void](Get-MeshClipCustomDevicesFromLines -Lines (Read-MeshClipTextDocument -Path $tempPath).Lines)
        [IO.File]::Move($tempPath, $paths.KdeConfigPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }

    [pscustomobject]@{
        Changed        = $true
        BackupPath     = $backupPath
        Devices        = $result.Devices
        OriginalExists = $document.Exists
        OriginalHash   = $document.Hash
        ResultHash     = Get-MeshClipFileHashSafe -Path $paths.KdeConfigPath
    }
}

function Restore-MeshClipKdeConfigChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Change
    )

    if (-not $Change.Changed) {
        return
    }

    $paths = Get-MeshClipPaths
    $currentHash = Get-MeshClipFileHashSafe -Path $paths.KdeConfigPath
    if ($currentHash -ne $Change.ResultHash) {
        throw 'KDE Connect config changed after the project write; automatic rollback was refused.'
    }

    if ($Change.OriginalExists) {
        if (-not $Change.BackupPath -or -not (Test-Path -LiteralPath $Change.BackupPath -PathType Leaf)) {
            throw 'The KDE Connect config preimage is unavailable; automatic rollback was refused.'
        }
        $configDirectory = Split-Path -Parent $paths.KdeConfigPath
        $tempPath = Join-Path $configDirectory "config.meshclip.rollback.$PID.tmp"
        try {
            [IO.File]::Copy($Change.BackupPath, $tempPath, $false)
            if ((Get-MeshClipFileHashSafe -Path $tempPath) -ne $Change.OriginalHash) {
                throw 'The KDE Connect config preimage hash did not match.'
            }
            [IO.File]::Move($tempPath, $paths.KdeConfigPath, $true)
        }
        finally {
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force
            }
        }
    }
    else {
        Remove-Item -LiteralPath $paths.KdeConfigPath -Force
    }
}

function Get-MeshClipState {
    [CmdletBinding()]
    param()

    $path = (Get-MeshClipPaths).StatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            schemaVersion          = $script:StateSchemaVersion
            addedPeers             = @()
            firewallRules          = @()
            disabledBroadFirewallRules = @()
            pendingTransaction     = $null
            startupShortcutCreated = $false
            tailscaleModeChanged   = $false
        }
    }
    try {
        $state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 30
    }
    catch {
        throw 'MeshClip Kit local state is corrupted. Refusing to modify the system.'
    }
    if ($state.schemaVersion -ne $script:StateSchemaVersion) {
        throw 'MeshClip Kit local state schema is unsupported.'
    }
    if (-not $state.PSObject.Properties['disabledBroadFirewallRules']) {
        $state | Add-Member -NotePropertyName disabledBroadFirewallRules -NotePropertyValue @()
    }
    if (-not $state.PSObject.Properties['pendingTransaction']) {
        $state | Add-Member -NotePropertyName pendingTransaction -NotePropertyValue $null
    }
    return $state
}

function Save-MeshClipState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State
    )

    $paths = Get-MeshClipPaths
    [IO.Directory]::CreateDirectory($paths.StateRoot) | Out-Null
    $tempPath = Join-Path $paths.StateRoot "user-state.$PID.tmp"
    try {
        $json = $State | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($tempPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        [void](Get-Content -Raw -LiteralPath $tempPath | ConvertFrom-Json -Depth 30)
        [IO.File]::Move($tempPath, $paths.StatePath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Get-MeshClipStartupInfo {
    [CmdletBinding()]
    param()

    $paths = Get-MeshClipPaths
    if (-not (Test-Path -LiteralPath $paths.StartupShortcut -PathType Leaf)) {
        return [pscustomobject]@{
            Exists            = $false
            TargetPath        = $null
            Matches           = $false
            OwnedAndUnchanged = $false
        }
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($paths.StartupShortcut)
    $expected = Get-MeshClipKdeExecutable -Kind indicator
    $ownedDescription = 'KDE Connect login startup verified by MeshClip Kit'
    $trustedTarget = [bool]($expected -and $shortcut.TargetPath -eq $expected)
    [pscustomobject]@{
        Exists            = $true
        TargetPath        = $shortcut.TargetPath
        Matches           = $trustedTarget
        OwnedAndUnchanged = [bool](
            $trustedTarget -and
            [string]::IsNullOrEmpty($shortcut.Arguments) -and
            $shortcut.WorkingDirectory -eq $env:USERPROFILE -and
            $shortcut.Description -eq $ownedDescription
        )
    }
}

function New-MeshClipStartupShortcut {
    [CmdletBinding()]
    param()

    $paths = Get-MeshClipPaths
    $indicator = Get-MeshClipKdeExecutable -Kind indicator
    if (-not $indicator) {
        throw 'KDE Connect indicator executable was not found.'
    }
    $existing = Get-MeshClipStartupInfo
    if ($existing.Exists) {
        if (-not $existing.Matches) {
            throw 'A different KDE Connect startup shortcut already exists. Refusing to overwrite it.'
        }
        return [pscustomobject]@{ Created = $false; Path = $paths.StartupShortcut }
    }

    [IO.Directory]::CreateDirectory((Split-Path -Parent $paths.StartupShortcut)) | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($paths.StartupShortcut)
    $shortcut.TargetPath = $indicator
    $shortcut.WorkingDirectory = $env:USERPROFILE
    $shortcut.Description = 'KDE Connect login startup verified by MeshClip Kit'
    $shortcut.Save()
    [pscustomobject]@{ Created = $true; Path = $paths.StartupShortcut }
}

function Get-MeshClipTailscaleAdapterAlias {
    [CmdletBinding()]
    param()

    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^Tailscale$' -or $_.InterfaceDescription -match 'Tailscale'
    })
    if ($adapters.Count -ne 1) {
        throw 'Exactly one Tailscale network adapter was not found.'
    }
    return $adapters[0].Name
}

function Get-MeshClipFirewallRuleNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Address
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Address)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).Substring(0, 12)
    @("MeshClipKit-$hash-TCP", "MeshClipKit-$hash-UDP")
}

function Test-MeshClipExactStringSet {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]] $Actual = @(),

        [AllowEmptyCollection()]
        [string[]] $Expected = @()
    )

    $actualValues = @($Actual | ForEach-Object { [string]$_ })
    $expectedValues = @($Expected | ForEach-Object { [string]$_ })
    if ($actualValues.Count -ne $expectedValues.Count) {
        return $false
    }

    $actualSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expectedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $actualValues) { $actualSet.Add($value) | Out-Null }
    foreach ($value in $expectedValues) { $expectedSet.Add($value) | Out-Null }
    return $actualSet.Count -eq $actualValues.Count -and
        $expectedSet.Count -eq $expectedValues.Count -and
        $actualSet.SetEquals($expectedSet)
}

function Test-MeshClipFirewallFilterContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ActualProtocol,
        [Parameter(Mandatory)] [string] $ExpectedProtocol,
        [Parameter(Mandatory)] [string[]] $ActualLocalPorts,
        [Parameter(Mandatory)] [string[]] $ExpectedLocalPorts,
        [Parameter(Mandatory)] [string[]] $ActualRemoteAddresses,
        [Parameter(Mandatory)] [string[]] $ExpectedRemoteAddresses,
        [Parameter(Mandatory)] [string[]] $ActualPrograms,
        [Parameter(Mandatory)] [string[]] $ExpectedPrograms,
        [Parameter(Mandatory)] [string[]] $ActualInterfaceAliases,
        [Parameter(Mandatory)] [string[]] $ExpectedInterfaceAliases
    )

    return $ActualProtocol -eq $ExpectedProtocol -and
        (Test-MeshClipExactStringSet -Actual $ActualLocalPorts -Expected $ExpectedLocalPorts) -and
        (Test-MeshClipExactStringSet -Actual $ActualRemoteAddresses -Expected $ExpectedRemoteAddresses) -and
        (Test-MeshClipExactStringSet -Actual $ActualPrograms -Expected $ExpectedPrograms) -and
        (Test-MeshClipExactStringSet -Actual $ActualInterfaceAliases -Expected $ExpectedInterfaceAliases)
}

function Test-MeshClipFirewallRuleCompliant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Rule,
        [Parameter(Mandatory)] [string] $Protocol,
        [Parameter(Mandatory)] [string] $Address,
        [Parameter(Mandatory)] [string] $Program,
        [Parameter(Mandatory)] [string] $InterfaceAlias
    )

    $ports = @($Rule | Get-NetFirewallPortFilter)
    $remotes = @($Rule | Get-NetFirewallAddressFilter)
    $applications = @($Rule | Get-NetFirewallApplicationFilter)
    $interfaces = @($Rule | Get-NetFirewallInterfaceFilter)
    if ($ports.Count -ne 1 -or $remotes.Count -ne 1 -or
        $applications.Count -ne 1 -or $interfaces.Count -ne 1) {
        return $false
    }

    return (
        $Rule.Group -eq $script:FirewallGroup -and
        $Rule.Direction.ToString() -eq 'Inbound' -and
        $Rule.Action.ToString() -eq 'Allow' -and
        $Rule.Enabled.ToString() -eq 'True' -and
        $Rule.EdgeTraversalPolicy.ToString() -eq 'Block' -and
        (Test-MeshClipFirewallFilterContract `
            -ActualProtocol $ports[0].Protocol.ToString() `
            -ExpectedProtocol $Protocol `
            -ActualLocalPorts @($ports[0].LocalPort) `
            -ExpectedLocalPorts @($script:FirewallPortRange) `
            -ActualRemoteAddresses @($remotes[0].RemoteAddress) `
            -ExpectedRemoteAddresses @($Address) `
            -ActualPrograms @($applications[0].Program) `
            -ExpectedPrograms @($Program) `
            -ActualInterfaceAliases @($interfaces[0].InterfaceAlias) `
            -ExpectedInterfaceAliases @($InterfaceAlias))
    )
}

function New-MeshClipFirewallRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Address
    )

    if (-not (Test-MeshClipAdministrator)) {
        throw 'Administrator privileges are required to create firewall rules.'
    }
    $daemon = Get-MeshClipKdeExecutable -Kind daemon
    if (-not $daemon) {
        throw 'KDE Connect daemon executable was not found.'
    }
    $adapter = Get-MeshClipTailscaleAdapterAlias
    $names = Get-MeshClipFirewallRuleNames -Address $Address
    $protocols = @('TCP', 'UDP')
    $created = [Collections.Generic.List[string]]::new()

    try {
        for ($i = 0; $i -lt $names.Count; $i++) {
            $existing = @(Get-NetFirewallRule -DisplayName $names[$i] -ErrorAction SilentlyContinue)
            if ($existing.Count -gt 0) {
                if ($existing.Count -ne 1 -or -not (Test-MeshClipFirewallRuleCompliant -Rule $existing[0] -Protocol $protocols[$i] -Address $Address -Program $daemon -InterfaceAlias $adapter)) {
                    throw "An existing rule named $($names[$i]) is not owned by MeshClip Kit or is too broad."
                }
                continue
            }

            New-NetFirewallRule `
                -DisplayName $names[$i] `
                -Group $script:FirewallGroup `
                -Description 'Created by MeshClip Kit for one approved Tailscale peer.' `
                -Direction Inbound `
                -Action Allow `
                -Enabled True `
                -Profile Any `
                -Protocol $protocols[$i] `
                -LocalPort $script:FirewallPortRange `
                -RemoteAddress $Address `
                -InterfaceAlias $adapter `
                -Program $daemon `
                -EdgeTraversalPolicy Block | Out-Null
            $created.Add($names[$i])
        }
    }
    catch {
        foreach ($name in $created) {
            Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue |
                Where-Object Group -eq $script:FirewallGroup |
                Remove-NetFirewallRule
        }
        throw
    }

    return [pscustomobject]@{
        Names        = @($names)
        CreatedNames = @($created)
    }
}

function Remove-MeshClipFirewallRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Names
    )

    if (-not (Test-MeshClipAdministrator)) {
        throw 'Administrator privileges are required to remove firewall rules.'
    }
    foreach ($name in $Names) {
        $rules = @(Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)
        foreach ($rule in $rules) {
            if ($rule.Group -ne $script:FirewallGroup) {
                throw "Refusing to remove a firewall rule not owned by MeshClip Kit: $name"
            }
            $rule | Remove-NetFirewallRule
        }
    }
}

function Test-MeshClipTailscaleIPv4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Address
    )

    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }
    $bytes = $parsed.GetAddressBytes()
    return $bytes[0] -eq 100 -and (($bytes[1] -band 0xC0) -eq 0x40)
}

function Get-MeshClipKdeFirewallAudit {
    [CmdletBinding()]
    param(
        [string] $Address
    )

    $daemon = Get-MeshClipKdeExecutable -Kind daemon
    if (-not $daemon) {
        return [pscustomobject]@{
            Status                = 'Missing'
            UnmanagedInboundAllow = 0
            BroadInboundAllow     = 0
            BroadRuleNames        = @()
        }
    }

    try {
        $applicationFilters = @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -ErrorAction Stop |
            Where-Object { $_.Program -eq $daemon })
        $seenRuleIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $unmanagedInboundAllow = 0
        $broadInboundAllow = 0
        $broadRuleNames = [Collections.Generic.List[string]]::new()
        $adapter = Get-MeshClipTailscaleAdapterAlias

        foreach ($applicationFilter in $applicationFilters) {
            $rules = @(Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $applicationFilter -ErrorAction Stop)
            foreach ($rule in $rules) {
                $ruleId = [string]$rule.InstanceID
                if ($ruleId -and -not $seenRuleIds.Add($ruleId)) {
                    continue
                }
                if ($rule.Direction.ToString() -ne 'Inbound' -or
                    $rule.Action.ToString() -ne 'Allow' -or
                    $rule.Enabled.ToString() -ne 'True' -or
                    $rule.Group -eq $script:FirewallGroup) {
                    continue
                }

                $unmanagedInboundAllow++
                $portFilters = @($rule | Get-NetFirewallPortFilter -ErrorAction Stop)
                $addressFilters = @($rule | Get-NetFirewallAddressFilter -ErrorAction Stop)
                $interfaceFilters = @($rule | Get-NetFirewallInterfaceFilter -ErrorAction Stop)
                $applicationFiltersForRule = @($rule | Get-NetFirewallApplicationFilter -ErrorAction Stop)
                $expectedRemote = if ($Address) { @($Address) } else { @() }
                $remoteAddresses = @($addressFilters | ForEach-Object { @($_.RemoteAddress) } | ForEach-Object { [string]$_ })
                $remoteIsExact = if ($Address) {
                    Test-MeshClipExactStringSet -Actual $remoteAddresses -Expected $expectedRemote
                }
                else {
                    $remoteAddresses.Count -eq 1 -and (Test-MeshClipTailscaleIPv4 -Address $remoteAddresses[0])
                }
                $filterIsExact = $portFilters.Count -eq 1 -and
                    $addressFilters.Count -eq 1 -and
                    $interfaceFilters.Count -eq 1 -and
                    $applicationFiltersForRule.Count -eq 1 -and
                    $remoteIsExact -and
                    (Test-MeshClipExactStringSet -Actual @($portFilters[0].LocalPort) -Expected @($script:FirewallPortRange)) -and
                    $portFilters[0].Protocol.ToString() -in @('TCP', 'UDP') -and
                    (Test-MeshClipExactStringSet -Actual @($interfaceFilters[0].InterfaceAlias) -Expected @($adapter)) -and
                    (Test-MeshClipExactStringSet -Actual @($applicationFiltersForRule[0].Program) -Expected @($daemon))
                if (-not $filterIsExact) {
                    $broadInboundAllow++
                    $broadRuleNames.Add([string]$rule.Name)
                }
            }
        }

        [pscustomobject]@{
            Status                 = 'Available'
            UnmanagedInboundAllow  = $unmanagedInboundAllow
            BroadInboundAllow      = $broadInboundAllow
            BroadRuleNames         = @($broadRuleNames)
        }
    }
    catch {
        [pscustomobject]@{
            Status                 = 'Unknown'
            UnmanagedInboundAllow  = 0
            BroadInboundAllow      = 0
            BroadRuleNames         = @()
        }
    }
}

function Disable-MeshClipBroadKdeFirewallRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Address
    )

    if (-not (Test-MeshClipAdministrator)) {
        throw 'Administrator privileges are required to harden firewall rules.'
    }
    $audit = Get-MeshClipKdeFirewallAudit -Address $Address
    if ($audit.Status -ne 'Available') {
        throw 'The unmanaged KDE firewall audit is unavailable; refusing to change firewall rules.'
    }
    $daemon = Get-MeshClipKdeExecutable -Kind daemon
    if (-not $daemon) {
        throw 'KDE Connect daemon executable was not found.'
    }
    $disabled = [Collections.Generic.List[string]]::new()
    try {
        foreach ($name in @($audit.BroadRuleNames)) {
            $rule = Get-NetFirewallRule -Name $name -ErrorAction Stop
            $applications = @($rule | Get-NetFirewallApplicationFilter -ErrorAction Stop)
            if ($rule.Group -eq $script:FirewallGroup -or
                $rule.Direction.ToString() -ne 'Inbound' -or
                $rule.Action.ToString() -ne 'Allow' -or
                $rule.Enabled.ToString() -ne 'True' -or
                $applications.Count -ne 1 -or
                -not (Test-MeshClipExactStringSet -Actual @($applications[0].Program) -Expected @($daemon))) {
                throw 'An unmanaged firewall rule changed during hardening; refusing to continue.'
            }
            $rule | Disable-NetFirewallRule -ErrorAction Stop
            $disabled.Add($name)
        }
        return @($disabled)
    }
    catch {
        foreach ($name in $disabled) {
            Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue |
                Where-Object { $_.Group -ne $script:FirewallGroup -and $_.Enabled.ToString() -eq 'False' } |
                Enable-NetFirewallRule -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Enable-MeshClipDisabledUnmanagedKdeFirewallRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Names
    )

    if (-not (Test-MeshClipAdministrator)) {
        throw 'Administrator privileges are required to restore firewall rules.'
    }
    $daemon = Get-MeshClipKdeExecutable -Kind daemon
    if (-not $daemon) {
        throw 'KDE Connect daemon executable was not found.'
    }
    $rulesToEnable = [Collections.Generic.List[object]]::new()
    foreach ($name in $Names) {
        $rule = Get-NetFirewallRule -Name $name -ErrorAction Stop
        $applications = @($rule | Get-NetFirewallApplicationFilter -ErrorAction Stop)
        if ($rule.Group -eq $script:FirewallGroup -or
            $rule.Direction.ToString() -ne 'Inbound' -or
            $rule.Action.ToString() -ne 'Allow' -or
            $rule.Enabled.ToString() -ne 'False' -or
            $applications.Count -ne 1 -or
            -not (Test-MeshClipExactStringSet -Actual @($applications[0].Program) -Expected @($daemon))) {
            throw 'A recorded unmanaged firewall rule no longer matches its restore contract.'
        }
        $rulesToEnable.Add($rule)
    }

    $enabled = [Collections.Generic.List[object]]::new()
    try {
        foreach ($rule in $rulesToEnable) {
            $rule | Enable-NetFirewallRule -ErrorAction Stop
            $enabled.Add($rule)
        }
    }
    catch {
        foreach ($rule in $enabled) {
            $rule | Disable-NetFirewallRule -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Get-MeshClipKdeDeviceSummary {
    [CmdletBinding()]
    param()

    $cli = Get-MeshClipKdeExecutable -Kind cli
    if (-not $cli) {
        return [pscustomobject]@{ Known = 0; Available = 0; Status = 'Missing' }
    }
    try {
        $known = Invoke-MeshClipExternal -FilePath $cli -ArgumentList @('--list-devices', '--id-only')
        $available = Invoke-MeshClipExternal -FilePath $cli -ArgumentList @('--list-available', '--id-only')
        [pscustomobject]@{
            Known     = @($known.Output | Where-Object { $_.Trim() }).Count
            Available = @($available.Output | Where-Object { $_.Trim() }).Count
            Status    = 'Available'
        }
    }
    catch {
        [pscustomobject]@{ Known = 0; Available = 0; Status = 'Unknown' }
    }
}

function Test-MeshClipCloudClipboardEnabled {
    [CmdletBinding()]
    param()

    $path = 'HKCU:\Software\Microsoft\Clipboard'
    $value = Get-ItemProperty -Path $path -Name EnableCloudClipboard -ErrorAction SilentlyContinue
    return [bool]($value -and $value.EnableCloudClipboard -eq 1)
}

Export-ModuleMember -Function @(
    'Get-MeshClipPaths',
    'Test-MeshClipAdministrator',
    'Enter-MeshClipOperationLock',
    'Exit-MeshClipOperationLock',
    'Get-MeshClipTrustedCommand',
    'Invoke-MeshClipExternal',
    'Get-MeshClipKdeInstallRoot',
    'Get-MeshClipKdeExecutable',
    'Get-MeshClipTailscaleStatus',
    'Get-MeshClipTailscalePreferences',
    'Resolve-MeshClipPeer',
    'Resolve-MeshClipApprovedWindowsPeer',
    'ConvertTo-MeshClipRedactedAddress',
    'Get-MeshClipFileHashSafe',
    'Read-MeshClipTextDocument',
    'Get-MeshClipCustomDevicesFromLines',
    'Add-MeshClipCustomDeviceToLines',
    'Remove-MeshClipCustomDeviceFromLines',
    'Repair-MeshClipLegacyDuplicateGeneralLines',
    'Write-MeshClipKdeConfigChange',
    'Restore-MeshClipKdeConfigChange',
    'Get-MeshClipState',
    'Save-MeshClipState',
    'Get-MeshClipStartupInfo',
    'New-MeshClipStartupShortcut',
    'Get-MeshClipTailscaleAdapterAlias',
    'Get-MeshClipFirewallRuleNames',
    'Test-MeshClipExactStringSet',
    'Test-MeshClipFirewallFilterContract',
    'Test-MeshClipFirewallRuleCompliant',
    'New-MeshClipFirewallRules',
    'Remove-MeshClipFirewallRules',
    'Get-MeshClipKdeFirewallAudit',
    'Disable-MeshClipBroadKdeFirewallRules',
    'Enable-MeshClipDisabledUnmanagedKdeFirewallRules',
    'Get-MeshClipKdeDeviceSummary',
    'Test-MeshClipCloudClipboardEnabled'
)

#Requires -Version 7.0

[CmdletBinding()]
param(
    [string] $Peer,
    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MeshClip.Common.psm1') -Force

$checks = [Collections.Generic.List[object]]::new()
function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail)
    $checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}

if (-not $IsWindows) {
    Add-Check 'Operating system' 'FAIL' 'Windows is required.'
}
elseif ([Environment]::OSVersion.Version.Build -ge 22000) {
    Add-Check 'Operating system' 'PASS' 'Windows 11 detected.'
}
else {
    Add-Check 'Operating system' 'FAIL' 'Current MVP requires Windows 11.'
}

Add-Check 'PowerShell' 'PASS' "PowerShell $($PSVersionTable.PSVersion)"

$tailscale = Get-MeshClipTrustedCommand -Name tailscale
$status = $null
$selected = $null
if (-not $tailscale) {
    Add-Check 'Tailscale installation' 'FAIL' 'Tailscale executable not found.'
}
else {
    $tailscaleVersion = (Get-Item -LiteralPath $tailscale).VersionInfo.ProductVersion
    $tailscaleVersionDetail = if ($tailscaleVersion) { "Trusted executable found (version $tailscaleVersion)." } else { 'Trusted executable found.' }
    Add-Check 'Tailscale installation' 'PASS' $tailscaleVersionDetail
    try {
        $tailscaleServices = @(Get-CimInstance Win32_Service -Filter "Name='Tailscale'" -ErrorAction Stop)
        if ($tailscaleServices.Count -eq 1 -and
            $tailscaleServices[0].StartMode -eq 'Auto' -and
            $tailscaleServices[0].State -eq 'Running') {
            Add-Check 'Tailscale Windows service' 'PASS' 'Service startup is automatic and the service is running.'
        }
        else {
            Add-Check 'Tailscale Windows service' 'FAIL' 'The expected automatic, running Tailscale service was not verified.'
        }
    }
    catch {
        Add-Check 'Tailscale Windows service' 'FAIL' 'Windows service state could not be read.'
    }
    try {
        $status = Get-MeshClipTailscaleStatus
        if ($status.BackendState -eq 'Running' -and $status.SelfOnline) {
            Add-Check 'Tailscale online' 'PASS' 'Backend is running and this device is online.'
        }
        else {
            Add-Check 'Tailscale online' 'FAIL' 'Complete official browser authentication or reconnect.'
        }
    }
    catch {
        Add-Check 'Tailscale online' 'FAIL' 'Status could not be safely parsed.'
    }

    try {
        $prefs = Get-MeshClipTailscalePreferences
        if ($prefs -and $prefs.ForceDaemon) {
            Add-Check 'Tailscale unattended' 'PASS' 'Run Unattended is enabled.'
        }
        else {
            Add-Check 'Tailscale unattended' 'WARN' 'Run Unattended is not verified.'
        }
    }
    catch {
        Add-Check 'Tailscale unattended' 'UNKNOWN' 'Preference could not be safely read.'
    }

    try {
        $shield = Invoke-MeshClipExternal -FilePath $tailscale -ArgumentList @('get', 'shields-up')
        if (($shield.Output -join '').Trim() -eq 'false') {
            Add-Check 'Tailscale shields-up' 'PASS' 'Incoming Tailnet connections are allowed.'
        }
        else {
            Add-Check 'Tailscale shields-up' 'FAIL' 'shields-up blocks incoming KDE Connect traffic.'
        }
    }
    catch {
        Add-Check 'Tailscale shields-up' 'UNKNOWN' 'Setting could not be safely read.'
    }
}

if ($status) {
    try {
        $selected = Resolve-MeshClipApprovedWindowsPeer -Status $status -Peer $Peer
        Add-Check 'Approved peer state' 'PASS' 'Exactly one approved Windows peer is online; identity is redacted.'

        try {
            Invoke-MeshClipExternal -FilePath $tailscale -ArgumentList @(
                'ping', '--c', '1', '--until-direct=false', '--timeout', '5s', $selected.Address
            ) | Out-Null
            Add-Check 'Tailnet peer reachability' 'PASS' 'tailscale ping succeeded.'
        }
        catch {
            Add-Check 'Tailnet peer reachability' 'FAIL' 'tailscale ping failed or timed out.'
        }
    }
    catch {
        Add-Check 'Approved peer state' 'FAIL' 'Exactly one online Windows peer could not be approved safely.'
    }
}

$indicator = Get-MeshClipKdeExecutable -Kind indicator
$daemon = Get-MeshClipKdeExecutable -Kind daemon
if ($indicator -and $daemon) {
    $kdeVersion = (Get-Item -LiteralPath $daemon).VersionInfo.ProductVersion
    $kdeVersionDetail = if ($kdeVersion) { "Trusted executables found (version $kdeVersion)." } else { 'Trusted indicator and daemon executables found.' }
    Add-Check 'KDE Connect installation' 'PASS' $kdeVersionDetail
}
else {
    Add-Check 'KDE Connect installation' 'FAIL' 'KDE Connect standard package was not found.'
}

if (Get-Process -Name kdeconnect-indicator -ErrorAction SilentlyContinue) {
    Add-Check 'KDE Connect indicator' 'PASS' 'User tray process is running.'
}
else {
    Add-Check 'KDE Connect indicator' 'WARN' 'User tray process is not running.'
}

$startup = Get-MeshClipStartupInfo
if ($startup.Exists -and $startup.Matches) {
    Add-Check 'KDE Connect login startup' 'PASS' 'Startup shortcut targets the trusted indicator.'
}
elseif ($startup.Exists) {
    Add-Check 'KDE Connect login startup' 'FAIL' 'A startup shortcut exists but targets an unexpected executable.'
}
else {
    Add-Check 'KDE Connect login startup' 'WARN' 'Startup shortcut was not found.'
}

$watchdogStartup = Get-MeshClipWatchdogStartupInfo
if ($watchdogStartup.Exists -and $watchdogStartup.OwnedAndUnchanged) {
    Add-Check 'KDE watchdog login startup' 'PASS' 'The silent project-owned watchdog shortcut is unchanged.'
}
elseif ($watchdogStartup.Exists) {
    Add-Check 'KDE watchdog login startup' 'FAIL' 'A watchdog shortcut exists but does not match the project-owned contract.'
}
else {
    Add-Check 'KDE watchdog login startup' 'FAIL' 'The KDE Connect watchdog login shortcut is not installed.'
}

try {
    $watchdogTask = Get-MeshClipWatchdogTaskInfo
    if ($watchdogTask.Exists -and $watchdogTask.Compliant) {
        Add-Check 'KDE watchdog supervisor' 'PASS' 'A current-user, limited task checks the watchdog every two minutes.'
    }
    elseif ($watchdogTask.Exists) {
        Add-Check 'KDE watchdog supervisor' 'FAIL' 'The named task does not match the required low-privilege contract.'
    }
    else {
        Add-Check 'KDE watchdog supervisor' 'FAIL' 'The KDE Connect watchdog supervisor task is not installed.'
    }
}
catch {
    Add-Check 'KDE watchdog supervisor' 'FAIL' 'The watchdog supervisor task could not be safely inspected.'
}

$watchdogProcess = Get-MeshClipWatchdogProcessInfo
$watchdogStatus = Get-MeshClipWatchdogStatus
if ($watchdogProcess.Running -and $watchdogStatus.Available -and $watchdogStatus.Fresh -and
    $watchdogStatus.Status -in @('Starting', 'Healthy', 'Restarted')) {
    Add-Check 'KDE watchdog runtime' 'PASS' 'Exactly one silent current-session watchdog has a fresh healthy heartbeat.'
}
elseif ($watchdogStartup.Exists -and $watchdogStartup.OwnedAndUnchanged) {
    Add-Check 'KDE watchdog runtime' 'FAIL' 'Watchdog startup is configured but its process or heartbeat is not healthy.'
}
else {
    Add-Check 'KDE watchdog runtime' 'FAIL' 'The required project-owned watchdog runtime is not healthy.'
}

$paths = Get-MeshClipPaths
try {
    $document = Read-MeshClipTextDocument -Path $paths.KdeConfigPath
    if ($document.Exists) {
        $custom = Get-MeshClipCustomDevicesFromLines -Lines $document.Lines
        if ($selected -and $selected.Address -in $custom.Devices) {
            Add-Check 'KDE custom peer' 'PASS' 'The selected peer is present in customDevices.'
        }
        elseif ($selected) {
            Add-Check 'KDE custom peer' 'FAIL' 'The selected peer is missing from customDevices.'
        }
        else {
            Add-Check 'KDE custom peer' 'WARN' "customDevices contains $($custom.Devices.Count) entries; no peer was selected for validation."
        }
    }
    else {
        Add-Check 'KDE config' 'FAIL' 'KDE Connect config has not been created.'
    }
}
catch {
    Add-Check 'KDE config' 'FAIL' 'Config is missing, duplicated, linked, or could not be parsed safely.'
}

if ($selected -and $daemon) {
    try {
        $adapter = Get-MeshClipTailscaleAdapterAlias
        $names = Get-MeshClipFirewallRuleNames -Address $selected.Address
        $protocols = @('TCP', 'UDP')
        $allCompliant = $true
        for ($i = 0; $i -lt $names.Count; $i++) {
            $rules = @(Get-NetFirewallRule -DisplayName $names[$i] -ErrorAction SilentlyContinue)
            if ($rules.Count -ne 1 -or -not (Test-MeshClipFirewallRuleCompliant -Rule $rules[0] -Protocol $protocols[$i] -Address $selected.Address -Program $daemon -InterfaceAlias $adapter)) {
                $allCompliant = $false
            }
        }
        if ($allCompliant) {
            Add-Check 'Exact-peer firewall' 'PASS' 'Both project-owned rules are narrowly scoped.'
        }
        else {
            Add-Check 'Exact-peer firewall' 'FAIL' 'One or more exact-peer rules are missing or noncompliant.'
        }
    }
    catch {
        Add-Check 'Exact-peer firewall' 'UNKNOWN' 'Firewall compliance could not be safely verified.'
    }
}

$firewallAudit = if ($selected) {
    Get-MeshClipKdeFirewallAudit -Address $selected.Address
}
else {
    Get-MeshClipKdeFirewallAudit
}
if ($firewallAudit.Status -eq 'Available' -and $firewallAudit.BroadInboundAllow -gt 0) {
    Add-Check 'Unmanaged KDE firewall' 'FAIL' 'Broad non-project inbound allow rules target KDE Connect; harden them before acceptance.'
}
elseif ($firewallAudit.Status -eq 'Available' -and $firewallAudit.UnmanagedInboundAllow -gt 0) {
    Add-Check 'Unmanaged KDE firewall' 'FAIL' 'Non-project inbound allow rules target KDE Connect; acceptance requires only project-owned exact-peer rules.'
}
elseif ($firewallAudit.Status -eq 'Available') {
    Add-Check 'Unmanaged KDE firewall' 'PASS' 'No non-project inbound allow rule targets the KDE Connect daemon.'
}
else {
    Add-Check 'Unmanaged KDE firewall' 'UNKNOWN' 'Existing KDE Connect firewall rules could not be audited.'
}

try {
    $localState = Get-MeshClipState
    if ($localState.pendingTransaction) {
        Add-Check 'Transaction state' 'FAIL' 'An interrupted configuration transaction requires review before more changes.'
    }
    else {
        Add-Check 'Transaction state' 'PASS' 'No interrupted project transaction is recorded.'
    }
}
catch {
    Add-Check 'Transaction state' 'FAIL' 'Local transaction state could not be read safely.'
}

$deviceSummary = Get-MeshClipKdeDeviceSummary
if ($deviceSummary.Status -eq 'Available' -and $deviceSummary.Available -gt 0) {
    Add-Check 'KDE peer availability' 'WARN' 'A KDE Connect device is visible. Manually confirm the same pairing identity on both computers.'
}
elseif ($deviceSummary.Status -eq 'Available') {
    Add-Check 'KDE peer availability' 'WARN' 'No KDE Connect device is currently available or paired.'
}
else {
    Add-Check 'KDE peer availability' 'UNKNOWN' 'KDE Connect CLI status could not be read.'
}

Add-Check 'Clipboard password sharing' 'WARN' 'Manually verify that each peer has Including passwords disabled.'
if (Test-MeshClipCloudClipboardEnabled) {
    Add-Check 'Windows cloud clipboard' 'WARN' 'Windows cloud clipboard appears enabled; KDE-written text may also sync through Microsoft cloud.'
}
else {
    Add-Check 'Windows cloud clipboard' 'PASS' 'Windows cloud clipboard is not detected as enabled.'
}

if ($AsJson) {
    $checks | ConvertTo-Json -Depth 5
}
else {
    $checks | Format-Table -AutoSize
}

if (@($checks | Where-Object Status -eq 'FAIL').Count -gt 0) {
    exit 1
}

#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [ValidateRange(10, 3600)]
    [int] $IntervalSeconds = 60,

    [ValidateRange(0, 300)]
    [int] $InitialDelaySeconds = 15,

    [switch] $RunOnce
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MeshClip.Common.psm1') -Force

if (-not $IsWindows) {
    throw 'The KDE Connect watchdog can only run on Windows.'
}

$mutex = [Threading.Mutex]::new($false, 'Local\MeshClipKit-KdeConnect-Watchdog')
if (-not $mutex.WaitOne(0)) {
    $mutex.Dispose()
    return
}

$restartCount = 0
$sessionId = (Get-Process -Id $PID).SessionId
try {
    Write-MeshClipWatchdogStatus -Status Starting -RestartCount $restartCount
    if ($InitialDelaySeconds -gt 0) {
        Start-Sleep -Seconds $InitialDelaySeconds
    }

    do {
        try {
            $indicator = Get-MeshClipKdeExecutable -Kind indicator
            if (-not $indicator) {
                Write-MeshClipWatchdogStatus -Status StartFailed -RestartCount $restartCount
            }
            else {
                $running = @(Get-Process -Name kdeconnect-indicator -ErrorAction SilentlyContinue | Where-Object {
                    $_.SessionId -eq $sessionId
                })
                if ($running.Count -eq 0) {
                    if ($PSCmdlet.ShouldProcess('KDE Connect indicator', 'Restart the trusted user-session executable')) {
                        Start-Process -FilePath $indicator
                        Start-Sleep -Seconds 5
                        $running = @(Get-Process -Name kdeconnect-indicator -ErrorAction SilentlyContinue | Where-Object {
                            $_.SessionId -eq $sessionId
                        })
                        if ($running.Count -eq 0) {
                            Write-MeshClipWatchdogStatus -Status StartFailed -RestartCount $restartCount
                        }
                        else {
                            $restartCount++
                            Write-MeshClipWatchdogStatus -Status Restarted -RestartCount $restartCount
                        }
                    }
                    else {
                        Write-MeshClipWatchdogStatus -Status StartSkipped -RestartCount $restartCount
                    }
                }
                else {
                    Write-MeshClipWatchdogStatus -Status Healthy -RestartCount $restartCount
                }
            }
        }
        catch {
            Write-MeshClipWatchdogStatus -Status Error -RestartCount $restartCount
        }

        if (-not $RunOnce) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    } while (-not $RunOnce)
}
finally {
    try { $mutex.ReleaseMutex() }
    catch { Write-Verbose 'The watchdog mutex was no longer owned during shutdown.' }
    $mutex.Dispose()
}
